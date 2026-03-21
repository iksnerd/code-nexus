defmodule ElixirNexus.Search.GraphBoost do
  @moduledoc "Graph-based re-ranking boost for search results."

  @doc """
  Apply graph relationship boost to search results.
  """
  def apply_graph_boost(results, graph) do
    # Seed: top 5 results by score
    seed_ids =
      results
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(5)
      |> Enum.map(&get_entity_id/1)

    seed_set = MapSet.new(seed_ids)

    Enum.map(results, fn result ->
      entity_id = get_entity_id(result)
      node = Map.get(graph, entity_id)

      graph_boost =
        cond do
          # Direct seed result
          MapSet.member?(seed_set, entity_id) -> 0.1

          # Has incoming references from other results
          node && (node["incoming_count"] || 0) > 0 ->
            min((node["incoming_count"] || 0) * 0.02, 0.1)

          # Calls something in the seed set
          node ->
            calls = node["calls"] || []
            related = Enum.count(calls, fn c ->
              Enum.any?(seed_ids, fn sid ->
                seed_node = Map.get(graph, sid)
                seed_node && String.downcase(seed_node["name"] || "") == String.downcase(c)
              end)
            end)
            min(related * 0.03, 0.1)

          true -> 0.0
        end

      %{result | score: result.score + graph_boost}
    end)
  end

  @doc """
  Extract entity name from a search result for graph matching.
  Uses entity name consistently since graph nodes are keyed by name.
  """
  def get_entity_id(result) do
    (result.entity && result.entity["name"]) || result.id
  end
end
