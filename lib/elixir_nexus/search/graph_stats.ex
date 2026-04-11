defmodule ElixirNexus.Search.GraphStats do
  @moduledoc "Aggregate codebase statistics, top-connected entities, and critical-file centrality."

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
      Regex.match?(~r/^[A-Z][a-z]{0,3}$/, name)
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

    top_connected =
      graph_nodes
      |> Map.values()
      |> Enum.reject(fn node ->
        name = node["name"] || ""
        String.length(name) <= 2 or graph_noise_name?(name)
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
end
