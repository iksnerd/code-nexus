defmodule ElixirNexus.RelationshipGraph do
  @moduledoc """
  Graph-based code relationship analysis.
  Builds and traverses code dependency graphs for improved search ranking.
  """
  require Logger

  @type entity_id :: String.t()
  @type graph :: %{required(entity_id()) => map()}
  @type relationship :: :calls | :is_a | :contains

  @doc """
  Build a relationship graph from search results with payloads.
  Returns a map of entity_id -> metadata with incoming/outgoing edges.
  """
  def build_graph(results) when is_list(results) do
    results
    |> Enum.reduce(%{}, fn result, acc ->
      entity_id = get_entity_id(result)
      payload = get_payload(result)

      node = %{
        "id" => entity_id,
        "name" => payload["name"],
        "type" => payload["entity_type"],
        "file_path" => payload["file_path"],
        "start_line" => payload["start_line"],
        "end_line" => payload["end_line"],
        "calls" => payload["calls"] || [],
        "is_a" => payload["is_a"] || [],
        "contains" => payload["contains"] || [],
        "outgoing_degree" =>
          length(payload["calls"] || []) +
            length(payload["is_a"] || []) +
            length(payload["contains"] || []),
        "incoming_count" => 0
      }

      Map.put(acc, entity_id, node)
    end)
    |> count_incoming_edges()
  end

  @doc """
  Find all entities that call a given function/module.
  """
  def find_callers(entity_name, graph) when is_map(graph) do
    name_lower = String.downcase(entity_name)

    graph
    |> Enum.filter(fn {_id, node} ->
      Enum.any?(node["calls"] || [], fn call ->
        call_lower = String.downcase(call)

        call_lower == name_lower or
          String.ends_with?(call_lower, "." <> name_lower) or
          String.ends_with?(name_lower, "." <> call_lower)
      end)
    end)
  end

  @doc """
  Find all entities that a given function/module calls.
  """
  def find_callees(entity_name, graph) when is_map(graph) do
    name_index = build_name_index(graph)

    case find_node_by_name_indexed(entity_name, name_index, graph) do
      nil ->
        []

      node ->
        (node["calls"] || [])
        |> Enum.map(&resolve_ref_indexed(&1, name_index))
        |> Enum.reject(&is_nil/1)
    end
  end

  @doc """
  Find parent modules (is_a relationships).
  """
  def find_parents(entity_name, graph) when is_map(graph) do
    name_index = build_name_index(graph)

    case find_node_by_name_indexed(entity_name, name_index, graph) do
      nil ->
        []

      node ->
        (node["is_a"] || [])
        |> Enum.map(&resolve_ref_indexed(&1, name_index))
        |> Enum.reject(&is_nil/1)
    end
  end

  @doc """
  Find child entities (contained_in relationships).
  """
  def find_children(entity_name, graph) when is_map(graph) do
    name_index = build_name_index(graph)

    case find_node_by_name_indexed(entity_name, name_index, graph) do
      nil ->
        []

      node ->
        (node["contains"] || [])
        |> Enum.map(&resolve_ref_indexed(&1, name_index))
        |> Enum.reject(&is_nil/1)
    end
  end

  @doc """
  Score results by relationship closeness to seed entities.
  Higher score = closer to query results in the graph.
  """
  def score_by_relationships(results, seed_entity_ids, graph) when is_list(results) and is_list(seed_entity_ids) do
    seed_set = MapSet.new(seed_entity_ids)

    results
    |> Enum.map(fn result ->
      entity_id = get_entity_id(result)
      score = compute_relationship_score(entity_id, seed_set, graph)
      Map.put(result, "relationship_score", score)
    end)
  end

  @doc """
  Re-rank search results by combining vector similarity with graph relationships.
  """
  def rerank_with_graph(results, graph, boost_factor \\ 0.3) when is_list(results) and is_map(graph) do
    # Get seed entity IDs from top results
    seed_ids = results |> Enum.take(5) |> Enum.map(&get_entity_id/1)

    # Score all results by relationships
    scored = score_by_relationships(results, seed_ids, graph)

    # Combine scores: vector_score * (1 + relationship_boost)
    reranked =
      scored
      |> Enum.map(fn result ->
        vector_score = result["score"] || 1.0
        rel_score = result["relationship_score"] || 0.0

        # Normalize relationship score to 0-1
        normalized_rel = min(rel_score / 10.0, 1.0)

        # Combined score: favor vector similarity, boost with relationships
        combined = vector_score * (1.0 + boost_factor * normalized_rel)

        result
        |> Map.put("combined_score", combined)
        |> Map.put("vector_score", vector_score)
      end)
      |> Enum.sort_by(& &1["combined_score"], :desc)

    reranked
  end

  @doc """
  Explain why an entity was ranked (for debugging).
  """
  def explain_ranking(result, graph) when is_map(result) and is_map(graph) do
    entity_id = get_entity_id(result)
    node = Map.get(graph, entity_id)

    %{
      "name" => result["entity"]["name"],
      "type" => result["entity"]["entity_type"],
      "vector_score" => result["score"],
      "combined_score" => result["combined_score"],
      "relationship_score" => result["relationship_score"],
      "outgoing_relationships" => node && node["outgoing_degree"],
      "incoming_relationships" => node && node["incoming_count"],
      "calls" => result["entity"]["calls"] || [],
      "is_a" => result["entity"]["is_a"] || [],
      "contains" => result["entity"]["contains"] || []
    }
  end

  # Private helpers

  defp count_incoming_edges(graph) do
    # Build a name lookup index for O(1) resolution instead of O(n) linear scan
    name_index = build_name_index(graph)

    # Count how many times each entity is referenced
    Enum.reduce(graph, graph, fn {_id, node}, acc ->
      Enum.reduce(node["calls"] ++ node["is_a"] ++ node["contains"], acc, fn ref, inner_acc ->
        case resolve_ref_indexed(ref, name_index) do
          nil ->
            inner_acc

          target_id ->
            target = Map.get(inner_acc, target_id)

            if target do
              updated = %{target | "incoming_count" => (target["incoming_count"] || 0) + 1}
              Map.put(inner_acc, target_id, updated)
            else
              inner_acc
            end
        end
      end)
    end)
  end

  # Build a map of lowercased name -> entity_id for fast lookups
  defp build_name_index(graph) do
    Enum.reduce(graph, %{}, fn {id, node}, acc ->
      name = String.downcase(node["name"] || "")
      if name != "", do: Map.put(acc, name, id), else: acc
    end)
  end

  # Resolve a reference using the precomputed index — exact match first, then partial
  defp resolve_ref_indexed(ref, name_index) do
    ref_lower = String.downcase(ref || "")

    if ref_lower == "" do
      nil
    else
      # Exact match (most common case)
      case Map.get(name_index, ref_lower) do
        nil ->
          # Partial match fallback — check if any indexed name is contained in the ref or vice versa
          Enum.find_value(name_index, fn {name, id} ->
            if String.contains?(ref_lower, name) or String.contains?(name, ref_lower), do: id
          end)

        id ->
          id
      end
    end
  end

  defp compute_relationship_score(entity_id, seed_set, graph) do
    if MapSet.member?(seed_set, entity_id) do
      100.0
    else
      case Map.get(graph, entity_id) do
        nil ->
          0.0

        node ->
          name_index = build_name_index(graph)
          direct_refs = node["calls"] ++ node["is_a"] ++ node["contains"]

          matched =
            Enum.count(direct_refs, fn ref ->
              case resolve_ref_indexed(ref, name_index) do
                nil -> false
                node_id -> MapSet.member?(seed_set, node_id)
              end
            end)

          incoming = node["incoming_count"] || 0
          matched * 5.0 + incoming * 2.0
      end
    end
  end

  # Find a node by name using the precomputed index — returns the node map (not id)
  defp find_node_by_name_indexed(name, name_index, graph) do
    case resolve_ref_indexed(name, name_index) do
      nil -> nil
      id -> Map.get(graph, id)
    end
  end

  defp get_entity_id(result) when is_map(result) do
    result[:id] || result["id"] || get_payload(result)["name"]
  end

  defp get_payload(result) when is_map(result) do
    result[:entity] || result["entity"] || result["payload"] || %{}
  end
end
