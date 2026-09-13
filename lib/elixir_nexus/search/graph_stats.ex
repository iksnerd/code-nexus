defmodule ElixirNexus.Search.GraphStats do
  @moduledoc "Aggregate codebase statistics, top-connected entities, and critical-file centrality."

  alias ElixirNexus.Search.{Builtins, EntityResolution}

  # Common framework/utility names that flood graph stats on shadcn/tailwind/React projects.
  @graph_noise_names ~w(
    cn clsx cva classnames twMerge cx Comp Slot forwardRef
    createContext useContext createElement createPortal createRef
    memo Fragment Children React
  )

  # Short PascalCase names (1-4 lowercase chars after initial cap) are almost always
  # UI wrapper aliases (Comp, Box, Row, Col, Btn, Nav, Ref, Ctx…) — not real app logic.
  defp graph_noise_name?(name) do
    name in @graph_noise_names or
      Regex.match?(~r/^[A-Z][a-z]{0,3}$/, name) or
      pattern_name?(name)
  end

  # Destructuring/binding patterns (`[canScrollNext, setCanScrollNext]`, `{ isMobile, state }`)
  # and object literals get captured as variable "entities" by the JS/TS extractor. Their
  # names are syntax, not identifiers — exclude them from every ranking.
  defp pattern_name?(name) do
    String.starts_with?(name, "[") or String.starts_with?(name, "{") or
      String.contains?(name, ",") or String.contains?(name, " ")
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
      |> Enum.group_by(fn node -> node["entity_type"] || node["type"] || "unknown" end)
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

    nodes = Map.values(graph_nodes)
    top_connected = top_connected(graph_nodes, 10)

    critical_files = compute_critical_files(graph_nodes)
    layers = compute_layers(nodes)

    {:ok,
     %{
       total_nodes: map_size(graph_nodes),
       total_chunks: length(chunks),
       entity_types: entity_types,
       edge_counts: %{calls: calls, imports: imports, contains: contains},
       top_connected: top_connected,
       languages: languages,
       layers: layers,
       critical_files: critical_files
     }}
  end

  # Architectural layer breakdown (entities per derived/configured layer). Gives an instant
  # read on the shape of a hexagonal/layered codebase. Layers with only "other" are omitted
  # when they'd be the sole entry, so flat projects don't get a noise row.
  defp compute_layers(nodes) do
    {config_root, config} = ElixirNexus.ProjectConfig.current()

    counts =
      nodes
      |> Enum.reduce(%{}, fn node, acc ->
        path = node["file_path"] || ""
        rel = if config_root, do: Path.relative_to(path, config_root), else: path
        layer = ElixirNexus.ProjectConfig.layer_for(config, rel)
        Map.update(acc, layer, 1, &(&1 + 1))
      end)
      |> Enum.map(fn {layer, count} -> %{layer: layer, count: count} end)
      |> Enum.sort_by(& &1.count, :desc)

    case counts do
      [%{layer: "other"}] -> []
      other -> other
    end
  end

  # For fan-in matching: a call like "utils.cn" or "a.b.format" keys on the final segment,
  # so a callee resolves to its bare-name node regardless of how the caller qualified it.
  @doc """
  Entities ranked by degree: calls out to project entities, contained members,
  and call fan-in. Shared by get_graph_stats and the dashboard so they agree.

  Imports (`is_a`) are excluded so barrel/provider modules don't outrank real
  hubs. Test files are left out entirely. Builtin and stdlib calls (`len`, `Map.get`, `new Error`) count for
  nothing. A qualified call `q.name` credits an entity only when `q` appears in
  its name (`Server.handle_call`) or when `q` is a variable and the entity is a
  method (`store.WritePiece`), so `searchParams.get` doesn't credit a `GET`
  route handler.
  """
  def top_connected(graph_nodes, limit) do
    # Test code is neither a hub nor evidence of one: a const repeated across test
    # files would top the list, and test call sites inflate what they exercise.
    nodes = graph_nodes |> Map.values() |> Enum.reject(&EntityResolution.test_file?(&1["file_path"] || ""))
    project_keys = MapSet.new(nodes, &call_key(&1["name"] || ""))
    fan_in = fan_in_of(nodes)

    nodes
    |> Enum.reject(fn node ->
      name = node["name"] || ""
      String.length(name) <= 2 or graph_noise_name?(name)
    end)
    |> Enum.map(fn node ->
      lang = node["language"]

      out =
        Enum.count(node["calls"] || [], fn call ->
          not Builtins.builtin_call?(call, lang) and MapSet.member?(project_keys, call_key(call))
        end)

      %{name: node["name"] || "?", degree: out + length(node["contains"] || []) + Map.get(fan_in, node_id(node), 0)}
    end)
    |> Enum.sort_by(& &1.degree, :desc)
    # Collapse same-named entities (overloads / re-declared helpers across files). Keep the highest.
    |> Enum.uniq_by(& &1.name)
    |> Enum.take(limit)
  end

  @doc """
  Call fan-in per graph node, keyed by `{file_path, name}`, with the same rules as
  top_connected/2 (no builtin or stdlib calls, qualifier-aware, no test callers).
  """
  def fan_in(graph_nodes) do
    graph_nodes
    |> Map.values()
    |> Enum.reject(&EntityResolution.test_file?(&1["file_path"] || ""))
    |> fan_in_of()
  end

  defp fan_in_of(nodes) do
    by_key = Enum.group_by(nodes, &call_key(&1["name"] || ""))

    Enum.reduce(nodes, %{}, fn caller, acc ->
      lang = caller["language"]

      caller["calls"]
      |> List.wrap()
      |> Enum.reject(&Builtins.builtin_call?(&1, lang))
      |> Enum.reduce(acc, fn call, acc ->
        by_key
        |> Map.get(call_key(call), [])
        |> Enum.filter(&credits?(call, &1))
        |> Enum.reduce(acc, fn target, acc -> Map.update(acc, node_id(target), 1, &(&1 + 1)) end)
      end)
    end)
  end

  defp credits?(call, target) do
    case String.split(to_string(call), ".") do
      [_bare] ->
        true

      parts ->
        qualifier = parts |> Enum.drop(-1) |> List.last()
        target_name = String.downcase(target["name"] || "")

        String.contains?(target_name, String.downcase(qualifier)) or
          (Regex.match?(~r/^[a-z_]/, qualifier) and (target["entity_type"] || target["type"]) == "method")
    end
  end

  defp node_id(node), do: {node["file_path"], node["name"]}

  defp call_key(call) do
    call |> to_string() |> String.downcase() |> String.split(".") |> List.last() |> Kernel.||("")
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

    # Deterministic source selection: BFS from the highest out-degree nodes (the natural
    # path origins) instead of a random sample. Was `Enum.take_random`, which reseeded every
    # call and made critical_files/centrality non-reproducible between identical queries.
    # Scale the sample with graph size so large codebases still get meaningful coverage.
    sample_count = min(max(50, div(map_size(graph_nodes), 10)), map_size(graph_nodes))

    sources =
      adj
      |> Enum.sort_by(fn {name, callees} -> {-length(callees), name} end)
      |> Enum.take(sample_count)
      |> Enum.map(&elem(&1, 0))

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
    # Tests and generated code sit on many paths without being places anyone edits.
    |> Enum.reject(fn {file, _score} -> EntityResolution.test_file?(file) or generated_file?(file) end)
    |> Enum.sort_by(fn {_f, s} -> -s end)
    |> Enum.take(10)
    |> Enum.map(fn {file, score} -> %{file_path: file, centrality_score: score} end)
  end

  defp generated_file?(path) do
    base = Path.basename(path)

    String.contains?(base, ["generated", ".gen.", "_pb.", ".pb.", ".min."]) or
      String.contains?(path, ["/dist/", "/build/", "/built/", "/__generated__/"])
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
end
