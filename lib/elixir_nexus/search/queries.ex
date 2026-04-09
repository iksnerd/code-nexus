defmodule ElixirNexus.Search.Queries do
  @moduledoc "Callee discovery and impact analysis queries against the code index."

  require Logger

  # Exported names that frameworks call via file conventions, not explicit JS call sites.
  # Filtering these prevents false positives in find_dead_code for JS/TS projects.
  @framework_convention_names ~w(
    GET POST PUT PATCH DELETE HEAD OPTIONS
    default generateStaticParams generateMetadata
    loader action headers links handle
  )

  # Next.js / SvelteKit / Remix file-based routing conventions.
  # Default exports from these files are called by the framework, not user code.
  @framework_convention_files ~w(
    page layout loading error not-found template route
    global-error global-not-found sitemap robots manifest
    default
  )

  # Common framework/utility names that flood graph stats on shadcn/tailwind projects.
  @graph_noise_names ~w(cn clsx cva classnames twMerge cx Comp Slot forwardRef)

  @doc """
  Transitive impact analysis: given a function, find everything that would be
  affected by changing it — callers, their callers, etc. up to `depth` levels.
  Returns a tree of impact with file/line info.
  """
  def analyze_impact(entity_name, depth \\ 3) do
    Logger.info("Analyzing impact of: #{entity_name}, depth: #{depth}")

    case get_all_entities_cached(2000) do
      {:ok, all_entities} ->
        # Build reverse edge index once: name_lower -> [referencing_entities]
        # Includes both calls and imports so import-only dependencies are tracked
        edge_index = build_reverse_edge_index(all_entities)
        tree = build_impact_tree(entity_name, edge_index, depth, MapSet.new())
        flat = flatten_impact_tree(tree)

        {:ok,
         %{
           root: entity_name,
           depth: depth,
           total_affected: length(flat),
           impact: tree,
           affected_files: flat |> Enum.map(& &1.file_path) |> Enum.uniq()
         }}

      error ->
        error
    end
  end

  # Build a reverse edge index: for each call or import name, list the entities that reference it.
  # This turns O(n) caller lookups into O(1) map lookups.
  # Indexes both `calls` (runtime invocations) and `is_a` (imports/dependencies).
  defp build_reverse_edge_index(entities) do
    Enum.reduce(entities, %{}, fn e, acc ->
      calls = e.entity["calls"] || []
      imports = e.entity["is_a"] || []

      acc =
        Enum.reduce(calls, acc, fn call, index ->
          key = String.downcase(call)
          Map.update(index, key, [e], fn existing -> [e | existing] end)
        end)

      Enum.reduce(imports, acc, fn imp, index ->
        key = String.downcase(imp)
        Map.update(index, key, [e], fn existing -> [e | existing] end)
      end)
    end)
  end

  defp build_impact_tree(_name, _call_index, 0, _visited), do: []

  defp build_impact_tree(name, call_index, depth, visited) do
    name_lower = String.downcase(name)

    # Find callers via index: exact match + partial matches (Module.func -> func)
    callers =
      call_index
      |> Enum.flat_map(fn {call_lower, caller_entities} ->
        if call_lower == name_lower or
             String.ends_with?(call_lower, "." <> name_lower) or
             String.ends_with?(name_lower, "." <> call_lower) do
          caller_entities
        else
          []
        end
      end)
      |> Enum.uniq_by(fn e -> e.entity["name"] end)
      |> Enum.reject(fn e ->
        entity_name = e.entity["name"] || ""
        MapSet.member?(visited, entity_name)
      end)

    Enum.map(callers, fn caller ->
      caller_name = caller.entity["name"]
      new_visited = MapSet.put(visited, caller_name)

      %{
        name: caller_name,
        file_path: caller.entity["file_path"],
        entity_type: caller.entity["entity_type"],
        start_line: caller.entity["start_line"],
        end_line: caller.entity["end_line"],
        affected_by: build_impact_tree(caller_name, call_index, depth - 1, new_visited)
      }
    end)
  end

  defp flatten_impact_tree(tree) do
    Enum.flat_map(tree, fn node ->
      [%{name: node.name, file_path: node.file_path} | flatten_impact_tree(node.affected_by)]
    end)
  end

  @doc """
  Find all entities that a specific function calls.
  """
  def find_callees(entity_name, limit \\ 20) do
    Logger.info("Finding callees of: #{entity_name}")

    case get_definition(entity_name) do
      {:ok, entity} ->
        calls = entity.entity["calls"] || []

        # Resolve each call to its entity definition where possible
        case get_all_entities_cached(2000) do
          {:ok, all_entities} ->
            caller_file = entity.entity["file_path"]

            resolved =
              calls
              |> Enum.take(limit)
              |> Enum.map(fn call_name ->
                resolve_call(call_name, all_entities, caller_file)
              end)

            {:ok, resolved}

          _ ->
            {:ok, Enum.map(Enum.take(calls, limit), &%{name: &1, resolved: false})}
        end

      error ->
        error
    end
  end

  defp get_definition(entity_name) do
    Logger.info("Looking up definition: #{entity_name}")

    # Use scroll with a filter to find by name (avoids needing a real vector)
    filter = %{
      "must" => [
        %{"key" => "name", "match" => %{"value" => entity_name}}
      ]
    }

    case ElixirNexus.QdrantClient.scroll_points(1, nil, filter) do
      {:ok, %{"result" => %{"points" => [result | _]}}} ->
        {:ok, %{id: result["id"], score: 0.0, entity: ElixirNexus.Search.format_payload(result["payload"])}}

      {:ok, _} ->
        # Fallback: try search with a dummy vector
        dummy_vector = List.duplicate(0.0, 768)

        case ElixirNexus.QdrantClient.search_with_filter(dummy_vector, filter, 1) do
          {:ok, %{"result" => [result | _]}} ->
            {:ok,
             %{id: result["id"], score: result["score"], entity: ElixirNexus.Search.format_payload(result["payload"])}}

          {:ok, _} ->
            {:error, :not_found}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Resolve a call name to an entity, trying multiple strategies
  defp resolve_call(call_name, all_entities, caller_file) do
    candidates = Enum.filter(all_entities, &matches_entity_name?(&1.entity["name"] || "", call_name))

    # Also try stripped method name: "adapter.createConnector" → "createConnector"
    candidates =
      if candidates == [] do
        method_name = call_name |> String.split(".") |> List.last()

        if method_name != call_name do
          Enum.filter(all_entities, &matches_entity_name?(&1.entity["name"] || "", method_name))
        else
          []
        end
      else
        candidates
      end

    case candidates do
      [] ->
        %{name: call_name, resolved: false}

      [single] ->
        single

      multiple ->
        # Prefer same-file match to avoid cross-file false positives
        same_file = Enum.find(multiple, fn e -> e.entity["file_path"] == caller_file end)
        same_file || List.first(multiple)
    end
  end

  # Check if an import path (e.g., "@/services/evidence-evaluator") matches a file path
  defp import_matches_file?(import_path, file_path) do
    # Skip bare package imports (no path separators = npm package, not local file)
    if not String.contains?(import_path, "/") do
      false
    else
      # Normalize: strip @/, ./, ../ prefixes
      normalized =
        import_path
        |> String.replace(~r"^@/", "")
        |> String.replace(~r"^\.\./", "")
        |> String.replace(~r"^\./", "")

      # File path without extension
      file_no_ext = String.replace(file_path, ~r"\.(ts|tsx|js|jsx)$", "")

      # The normalized import path must be a suffix of the file path
      String.ends_with?(file_no_ext, normalized)
    end
  end

  defp matches_entity_name?(call, entity_name) do
    call_lower = String.downcase(call)
    name_lower = String.downcase(entity_name)

    # Exact match
    # Call is "Module.function" and entity is "function"
    # Call is "function" and entity is "Module.function"
    call_lower == name_lower ||
      String.ends_with?(call_lower, "." <> name_lower) ||
      String.ends_with?(name_lower, "." <> call_lower)
  end

  @doc """
  Find files structurally coupled to the given file via shared call edges.
  Returns top `limit` files ranked by coupling strength.
  """
  def get_community_context(file_path, limit \\ 10) do
    Logger.info("Getting community context for: #{file_path}")

    case get_all_entities_cached(2000) do
      {:ok, all_entities} ->
        target_entities = Enum.filter(all_entities, &(&1.entity["file_path"] == file_path))
        target_names = MapSet.new(target_entities, & &1.entity["name"])
        # Build lowercase index for O(1) name matching
        target_names_lower = MapSet.new(target_names, &String.downcase/1)
        # Exclude internal calls (calls that resolve to same-file entities)
        target_calls =
          target_entities
          |> Enum.flat_map(&(&1.entity["calls"] || []))
          |> Enum.reject(fn call ->
            call_lower = String.downcase(call)

            MapSet.member?(target_names_lower, call_lower) or
              Enum.any?(target_names, &matches_entity_name?(call, &1))
          end)

        target_calls_lower = MapSet.new(target_calls, &String.downcase/1)

        coupled =
          all_entities
          |> Enum.reject(&(&1.entity["file_path"] == file_path))
          |> Enum.flat_map(fn entity ->
            name = entity.entity["name"] || ""
            name_lower = String.downcase(name)
            calls = entity.entity["calls"] || []
            other_path = entity.entity["file_path"]

            # They call us (outgoing_hits) — check calls against target names
            outgoing =
              calls
              |> Enum.filter(fn c ->
                c_lower = String.downcase(c)

                MapSet.member?(target_names_lower, c_lower) or
                  Enum.any?(target_names, &matches_entity_name?(c, &1))
              end)
              |> Enum.map(fn c ->
                target = Enum.find(target_names, &matches_entity_name?(c, &1))
                %{from: name, to: target, direction: :incoming}
              end)

            # We call them (incoming_hits) — check if target calls this entity
            incoming =
              if MapSet.member?(target_calls_lower, name_lower) or
                   Enum.any?(target_calls, &matches_entity_name?(&1, name)) do
                caller =
                  Enum.find(target_entities, fn te ->
                    Enum.any?(te.entity["calls"] || [], &matches_entity_name?(&1, name))
                  end)

                [%{from: (caller && caller.entity["name"]) || "unknown", to: name, direction: :outgoing}]
              else
                []
              end

            # Import-path coupling: check all entities' is_a (import sources)
            import_connections =
              (entity.entity["is_a"] || [])
              |> Enum.filter(&import_matches_file?(&1, file_path))
              |> Enum.map(fn _imp ->
                %{from: name, to: Path.basename(file_path), direction: :imports}
              end)

            # Reverse import coupling: check if target file's entities import from this entity's file
            reverse_import_connections =
              target_entities
              |> Enum.flat_map(fn te ->
                (te.entity["is_a"] || [])
                |> Enum.filter(&import_matches_file?(&1, other_path))
                |> Enum.map(fn _imp ->
                  %{from: Path.basename(file_path), to: name, direction: :imported_by}
                end)
              end)

            connections = outgoing ++ incoming ++ import_connections ++ reverse_import_connections

            if connections != [] do
              [{other_path, length(connections), connections}]
            else
              []
            end
          end)
          |> Enum.group_by(&elem(&1, 0))
          |> Enum.map(fn {path, entries} ->
            score = entries |> Enum.map(&elem(&1, 1)) |> Enum.sum()
            connections = entries |> Enum.flat_map(&elem(&1, 2)) |> Enum.uniq()
            %{file_path: path, coupling_score: score, connections: connections}
          end)
          |> Enum.sort_by(& &1.coupling_score, :desc)
          |> Enum.take(limit)

        {:ok,
         %{
           file: file_path,
           entities_in_file: length(target_entities),
           coupled_files: coupled
         }}

      error ->
        error
    end
  end

  @doc """
  Find exported functions/methods with zero callers (dead code).
  """
  def find_dead_code(opts \\ []) do
    path_prefix = Keyword.get(opts, :path_prefix)

    case get_all_entities_cached(2000) do
      {:ok, all_entities} ->
        # Build reverse call index (calls only, not imports).
        # Also build a suffix set: for dotted calls like "utils.format", store the short
        # name "format" so qualified-name lookup is O(1) instead of O(n) per entity.
        {call_index, call_suffix_set} =
          Enum.reduce(all_entities, {%{}, MapSet.new()}, fn e, {index, suffixes} ->
            Enum.reduce(e.entity["calls"] || [], {index, suffixes}, fn call, {idx, sfx} ->
              key = String.downcase(call)
              idx = Map.put(idx, key, true)

              sfx =
                case String.split(key, ".") do
                  [_mod, short] -> MapSet.put(sfx, short)
                  [_mod, _mid, short] -> MapSet.put(sfx, short)
                  _ -> sfx
                end

              {idx, sfx}
            end)
          end)

        # Find public functions/methods with zero callers
        dead =
          all_entities
          |> Enum.filter(fn e ->
            type = e.entity["entity_type"]
            vis = e.entity["visibility"]
            type in ["function", "method"] and vis in ["public", nil]
          end)
          |> then(fn entities ->
            if path_prefix do
              Enum.filter(entities, &String.starts_with?(&1.entity["file_path"] || "", path_prefix))
            else
              entities
            end
          end)
          |> Enum.reject(fn e ->
            lang = e.entity["language"] || ""
            name = e.entity["name"] || ""
            file_path = e.entity["file_path"] || ""
            basename = file_path |> Path.basename() |> String.replace(~r/\.[^.]+$/, "")

            js_or_ts?(lang) and
              (name in @framework_convention_names or
                 # PascalCase components in convention files are default exports called by the
                 # framework (e.g. TorrentsLoading in loading.tsx, RootLayout in layout.tsx).
                 (Regex.match?(~r/^[A-Z]/, name) and basename in @framework_convention_files))
          end)
          |> Enum.filter(fn e ->
            name = e.entity["name"] || ""
            name_lower = String.downcase(name)
            # No entity calls this function (exact match or qualified suffix match)
            not Map.has_key?(call_index, name_lower) and
              not MapSet.member?(call_suffix_set, name_lower)
          end)
          |> Enum.map(fn e ->
            %{
              name: e.entity["name"],
              file_path: e.entity["file_path"],
              entity_type: e.entity["entity_type"],
              start_line: e.entity["start_line"]
            }
          end)

        total_public =
          all_entities
          |> Enum.count(fn e ->
            type = e.entity["entity_type"]
            vis = e.entity["visibility"]
            type in ["function", "method"] and vis in ["public", nil]
          end)

        has_js_ts =
          Enum.any?(all_entities, fn e -> js_or_ts?(e.entity["language"] || "") end)

        warning =
          if has_js_ts do
            "Results may include false positives for framework-exported functions " <>
              "(Next.js/SvelteKit/Remix route handlers and page components are called " <>
              "by the framework via file conventions, not explicit JS call sites). " <>
              "Known convention names (GET, POST, default, etc.) are pre-filtered."
          end

        {:ok,
         %{
           dead_functions: dead,
           total_public: total_public,
           dead_count: length(dead),
           warning: warning
         }}

      error ->
        error
    end
  end

  defp js_or_ts?(lang) do
    String.contains?(lang, "javascript") or String.contains?(lang, "typescript") or
      lang in ["tsx", "jsx"]
  end

  defp get_all_entities_cached(limit) do
    chunks =
      try do
        ElixirNexus.ChunkCache.all()
      rescue
        _ -> []
      end

    if is_list(chunks) and chunks != [] do
      entities =
        Enum.map(chunks, fn chunk ->
          %{
            id: chunk.id,
            score: 0.0,
            entity: %{
              "file_path" => chunk.file_path,
              "entity_type" => to_string(chunk.entity_type),
              "name" => chunk.name,
              "start_line" => chunk.start_line,
              "end_line" => chunk.end_line,
              "module_path" => chunk.module_path,
              "visibility" => chunk.visibility && to_string(chunk.visibility),
              "parameters" => chunk.parameters,
              "calls" => chunk.calls || [],
              "is_a" => chunk.is_a || [],
              "contains" => chunk.contains || [],
              "content" => chunk.content,
              "language" => chunk[:language] && to_string(chunk[:language])
            }
          }
        end)

      {:ok, Enum.take(entities, limit)}
    else
      # Fallback to Qdrant scroll — slow for large collections
      get_all_entities(limit)
    end
  end

  @doc """
  Find all entities that call a specific function.
  Inverse of find_callees — walks call edges inbound.
  """
  def find_callers(entity_name, limit \\ 20) do
    call_callers = ElixirNexus.GraphCache.find_callers(entity_name)
    import_callers = ElixirNexus.GraphCache.find_importers(entity_name)

    # Merge and deduplicate by id, preferring call callers
    all_callers =
      (call_callers ++ import_callers)
      |> Enum.uniq_by(fn {id, _node} -> id end)

    results =
      all_callers
      |> Enum.take(limit)
      |> Enum.map(fn {id, node} ->
        %{
          id: id,
          score: 0.0,
          entity: %{
            "name" => node["name"],
            "file_path" => node["file_path"],
            "entity_type" => node["type"],
            "start_line" => 0,
            "end_line" => 0,
            "calls" => node["calls"] || [],
            "is_a" => node["is_a"] || [],
            "contains" => node["contains"] || []
          }
        }
      end)

    {:ok, results}
  end

  @doc """
  Aggregate stats about the indexed codebase: node counts, edge counts,
  entity type breakdown, language distribution, and top connected entities.
  """
  def get_graph_stats do
    graph_nodes = ElixirNexus.GraphCache.all_nodes()
    chunks = ElixirNexus.ChunkCache.all()

    entity_types =
      graph_nodes
      |> Map.values()
      |> Enum.group_by(fn node -> node["type"] || node["entity_type"] || "unknown" end)
      |> Enum.map(fn {type, nodes} -> %{type: type, count: length(nodes)} end)
      |> Enum.sort_by(& &1.count, :desc)

    languages =
      chunks
      |> Enum.group_by(fn chunk -> to_string(chunk[:language] || chunk.language || "unknown") end)
      |> Enum.map(fn {lang, cs} -> %{language: lang, count: length(cs)} end)
      |> Enum.sort_by(& &1.count, :desc)

    {calls, imports, contains} =
      Enum.reduce(Map.values(graph_nodes), {0, 0, 0}, fn node, {c, i, co} ->
        {
          c + length(node["calls"] || []),
          i + length(node["is_a"] || []),
          co + length(node["contains"] || [])
        }
      end)

    top_connected =
      graph_nodes
      |> Map.values()
      |> Enum.reject(fn node ->
        name = node["name"] || ""
        String.length(name) <= 2 or name in @graph_noise_names
      end)
      |> Enum.map(fn node ->
        degree = (node["outgoing_degree"] || 0) + (node["incoming_count"] || 0)
        %{name: node["name"] || "?", degree: degree}
      end)
      |> Enum.sort_by(& &1.degree, :desc)
      |> Enum.take(10)

    critical_files = compute_critical_files(graph_nodes)

    {:ok,
     %{
       total_nodes: map_size(graph_nodes),
       total_chunks: length(chunks),
       entity_types: entity_types,
       edge_counts: %{calls: calls, imports: imports, contains: contains},
       top_connected: top_connected,
       languages: languages,
       critical_files: critical_files
     }}
  end

  # Approximate betweenness centrality via sampled BFS.
  # Identifies files that are bottlenecks — everything flows through them.
  defp compute_critical_files(graph_nodes) when map_size(graph_nodes) < 3, do: []

  defp compute_critical_files(graph_nodes) do
    nodes = Map.values(graph_nodes)
    # Build adjacency: name_lower -> [name_lower of callees]
    adj =
      Enum.reduce(nodes, %{}, fn node, acc ->
        name = String.downcase(node["name"] || "")
        callees = Enum.map(node["calls"] || [], &String.downcase/1)
        Map.put(acc, name, callees)
      end)

    all_names = Map.keys(adj)
    # Sample up to 30 source nodes for BFS
    sample_count = min(30, length(all_names))
    sources = Enum.take_random(all_names, sample_count)

    # Count how many shortest paths pass through each node
    centrality =
      Enum.reduce(sources, %{}, fn source, scores ->
        bfs_centrality(source, adj, scores)
      end)

    # Group by file path and sum scores
    name_to_file =
      Enum.reduce(nodes, %{}, fn node, acc ->
        Map.put(acc, String.downcase(node["name"] || ""), node["file_path"])
      end)

    centrality
    |> Enum.reduce(%{}, fn {name, score}, acc ->
      case Map.get(name_to_file, name) do
        nil -> acc
        file -> Map.update(acc, file, score, &(&1 + score))
      end
    end)
    |> Enum.sort_by(fn {_f, s} -> -s end)
    |> Enum.take(10)
    |> Enum.map(fn {file, score} -> %{file_path: file, centrality_score: score} end)
  end

  defp bfs_centrality(source, adj, scores) do
    # BFS from source, tracking predecessors for shortest paths
    queue = :queue.from_list([source])
    visited = MapSet.new([source])
    # predecessor map: node -> parent in BFS tree
    preds = %{}

    {_visited, preds} = bfs_loop(queue, adj, visited, preds)

    # For each reachable node, walk back through predecessors and count intermediaries
    Enum.reduce(preds, scores, fn {node, _parent}, acc ->
      # Walk path from node back to source, collect intermediaries (exclude source and node)
      intermediaries = collect_intermediaries(node, preds, source)

      Enum.reduce(intermediaries, acc, fn mid, inner ->
        Map.update(inner, mid, 1, &(&1 + 1))
      end)
    end)
  end

  defp collect_intermediaries(node, preds, source) do
    do_collect(node, preds, source, [])
  end

  defp do_collect(node, preds, source, acc) do
    case Map.get(preds, node) do
      nil -> acc
      ^source -> acc
      parent -> do_collect(parent, preds, source, [parent | acc])
    end
  end

  defp bfs_loop(queue, adj, visited, preds) do
    case :queue.out(queue) do
      {:empty, _} ->
        {visited, preds}

      {{:value, current}, rest} ->
        neighbors = Map.get(adj, current, [])

        {new_queue, new_visited, new_preds} =
          Enum.reduce(neighbors, {rest, visited, preds}, fn neighbor, {q, vis, p} ->
            if MapSet.member?(vis, neighbor) do
              {q, vis, p}
            else
              {
                :queue.in(neighbor, q),
                MapSet.put(vis, neighbor),
                Map.put(p, neighbor, current)
              }
            end
          end)

        bfs_loop(new_queue, adj, new_visited, new_preds)
    end
  end

  @doc """
  Find a module's hierarchy: parent behaviours/uses (is_a) and contained entities (contains).
  """
  def find_module_hierarchy(entity_name) do
    Logger.info("Finding module hierarchy for: #{entity_name}")

    case get_all_entities_cached(2000) do
      {:ok, all_entities} ->
        target = find_entity_multi_strategy(entity_name, all_entities)

        case target do
          nil ->
            {:error, :not_found}

          target ->
            parent_names = target.entity["is_a"] || []
            child_names = target.entity["contains"] || []

            parents = resolve_names(parent_names, all_entities)
            children = resolve_names(child_names, all_entities)

            {:ok,
             %{
               name: target.entity["name"],
               entity_type: target.entity["entity_type"],
               file_path: target.entity["file_path"],
               parents: parents,
               children: children
             }}
        end

      error ->
        error
    end
  end

  # Multi-strategy entity lookup: exact match, then file-path match, then substring
  defp find_entity_multi_strategy(name, entities) do
    # 1. Exact match (current behavior)
    # 2. File-path-based: basename matches query
    # 3. Substring: entity name contains query or vice versa
    Enum.find(entities, fn e ->
      matches_entity_name?(e.entity["name"] || "", name)
    end) ||
      Enum.find(entities, fn e ->
        file_path_matches_name?(e.entity["file_path"] || "", name)
      end) ||
      Enum.find(entities, fn e ->
        e_name = String.downcase(e.entity["name"] || "")
        q_name = String.downcase(name)

        e_name != "" and q_name != "" and
          (String.contains?(e_name, q_name) or String.contains?(q_name, e_name))
      end)
  end

  defp file_path_matches_name?(file_path, name) when file_path == "" or name == "", do: false

  defp file_path_matches_name?(file_path, name) do
    basename = file_path |> Path.basename() |> Path.rootname()
    normalize_name(basename) == normalize_name(name)
  end

  # Normalize: kebab-case, camelCase, PascalCase → lowercase
  defp normalize_name(name) do
    name
    |> String.replace(~r/[-_]/, "")
    |> String.downcase()
  end

  defp resolve_names(names, all_entities) do
    Enum.map(names, fn name ->
      case Enum.find(all_entities, fn e ->
             matches_entity_name?(e.entity["name"] || "", name)
           end) do
        nil ->
          %{name: name, resolved: false}

        found ->
          %{
            name: found.entity["name"],
            file_path: found.entity["file_path"],
            entity_type: found.entity["entity_type"],
            resolved: true
          }
      end
    end)
  end

  defp get_all_entities(limit) do
    scroll_all_points(limit, nil, [])
  end

  # Use list prepend + reverse to avoid O(n^2) list append
  defp scroll_all_points(remaining, _offset, acc) when remaining <= 0, do: {:ok, Enum.reverse(acc)}

  defp scroll_all_points(remaining, offset, acc) do
    page_size = min(remaining, 100)

    case ElixirNexus.QdrantClient.scroll_points(page_size, offset) do
      {:ok, %{"result" => %{"points" => points, "next_page_offset" => next_offset}}}
      when is_list(points) and points != [] ->
        entities =
          Enum.map(points, fn p ->
            %{id: p["id"], score: 0.0, entity: ElixirNexus.Search.format_payload(p["payload"])}
          end)

        if next_offset do
          scroll_all_points(remaining - length(points), next_offset, Enum.reverse(entities) ++ acc)
        else
          {:ok, Enum.reverse(Enum.reverse(entities) ++ acc)}
        end

      {:ok, %{"result" => %{"points" => points}}} when is_list(points) ->
        entities =
          Enum.map(points, fn p ->
            %{id: p["id"], score: 0.0, entity: ElixirNexus.Search.format_payload(p["payload"])}
          end)

        {:ok, Enum.reverse(Enum.reverse(entities) ++ acc)}

      {:ok, _} ->
        {:ok, Enum.reverse(acc)}

      {:error, reason} ->
        if acc != [], do: {:ok, Enum.reverse(acc)}, else: {:error, reason}
    end
  end
end
