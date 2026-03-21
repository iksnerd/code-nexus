defmodule ElixirNexus.Search.Queries do
  @moduledoc "Callee discovery and impact analysis queries against the code index."

  require Logger

  @doc """
  Transitive impact analysis: given a function, find everything that would be
  affected by changing it — callers, their callers, etc. up to `depth` levels.
  Returns a tree of impact with file/line info.
  """
  def analyze_impact(entity_name, depth \\ 3) do
    Logger.info("Analyzing impact of: #{entity_name}, depth: #{depth}")

    case get_all_entities_cached(2000) do
      {:ok, all_entities} ->
        # Build reverse call index once: callee_name_lower -> [caller_entities]
        call_index = build_reverse_call_index(all_entities)
        tree = build_impact_tree(entity_name, call_index, depth, MapSet.new())
        flat = flatten_impact_tree(tree)

        {:ok, %{
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

  # Build a reverse call index: for each call name, list the entities that make that call.
  # This turns O(n) caller lookups into O(1) map lookups.
  defp build_reverse_call_index(entities) do
    Enum.reduce(entities, %{}, fn e, acc ->
      calls = e.entity["calls"] || []
      Enum.reduce(calls, acc, fn call, index ->
        key = String.downcase(call)
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
        dummy_vector = List.duplicate(0.0, 384)

        case ElixirNexus.QdrantClient.search_with_filter(dummy_vector, filter, 1) do
          {:ok, %{"result" => [result | _]}} ->
            {:ok, %{id: result["id"], score: result["score"], entity: ElixirNexus.Search.format_payload(result["payload"])}}

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
      [] -> %{name: call_name, resolved: false}
      [single] -> single
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
    call_lower == name_lower ||
      # Call is "Module.function" and entity is "function"
      String.ends_with?(call_lower, "." <> name_lower) ||
      # Call is "function" and entity is "Module.function"
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
        target_names = MapSet.new(target_entities, &(&1.entity["name"]))
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
                caller = Enum.find(target_entities, fn te ->
                  Enum.any?(te.entity["calls"] || [], &matches_entity_name?(&1, name))
                end)
                [%{from: (caller && caller.entity["name"]) || "unknown", to: name, direction: :outgoing}]
              else
                []
              end

            # Import-path coupling: only check module entities' is_a (import sources)
            import_connections =
              if entity.entity["entity_type"] == "module" do
                imports = entity.entity["is_a"] || []
                if Enum.any?(imports, &import_matches_file?(&1, file_path)) do
                  [%{from: name, to: Path.basename(file_path), direction: :imports}]
                else
                  []
                end
              else
                []
              end

            connections = outgoing ++ incoming ++ import_connections

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

        {:ok, %{
          file: file_path,
          entities_in_file: length(target_entities),
          coupled_files: coupled
        }}

      error ->
        error
    end
  end

  defp get_all_entities_cached(limit) do
    chunks = try do
      ElixirNexus.ChunkCache.all()
    rescue
      _ -> []
    catch
      :error, _ -> []
    end

    if is_list(chunks) and chunks != [] do
      entities = Enum.map(chunks, fn chunk ->
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
    callers = ElixirNexus.GraphCache.find_callers(entity_name)

    results =
      callers
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
      |> Enum.map(fn node ->
        degree = (node["outgoing_degree"] || 0) + (node["incoming_count"] || 0)
        %{name: node["name"] || "?", degree: degree}
      end)
      |> Enum.sort_by(& &1.degree, :desc)
      |> Enum.take(10)

    {:ok, %{
      total_nodes: map_size(graph_nodes),
      total_chunks: length(chunks),
      entity_types: entity_types,
      edge_counts: %{calls: calls, imports: imports, contains: contains},
      top_connected: top_connected,
      languages: languages
    }}
  end

  @doc """
  Find a module's hierarchy: parent behaviours/uses (is_a) and contained entities (contains).
  """
  def find_module_hierarchy(entity_name) do
    Logger.info("Finding module hierarchy for: #{entity_name}")

    case get_all_entities_cached(2000) do
      {:ok, all_entities} ->
        case Enum.find(all_entities, fn e ->
          matches_entity_name?(e.entity["name"] || "", entity_name)
        end) do
          nil ->
            {:error, :not_found}

          target ->
            parent_names = target.entity["is_a"] || []
            child_names = target.entity["contains"] || []

            parents = resolve_names(parent_names, all_entities)
            children = resolve_names(child_names, all_entities)

            {:ok, %{
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

  defp resolve_names(names, all_entities) do
    Enum.map(names, fn name ->
      case Enum.find(all_entities, fn e ->
        matches_entity_name?(e.entity["name"] || "", name)
      end) do
        nil -> %{name: name, resolved: false}
        found -> %{name: found.entity["name"], file_path: found.entity["file_path"],
                   entity_type: found.entity["entity_type"], resolved: true}
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
        entities = Enum.map(points, fn p ->
          %{id: p["id"], score: 0.0, entity: ElixirNexus.Search.format_payload(p["payload"])}
        end)
        if next_offset do
          scroll_all_points(remaining - length(points), next_offset, Enum.reverse(entities) ++ acc)
        else
          {:ok, Enum.reverse(Enum.reverse(entities) ++ acc)}
        end

      {:ok, %{"result" => %{"points" => points}}} when is_list(points) ->
        entities = Enum.map(points, fn p ->
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
