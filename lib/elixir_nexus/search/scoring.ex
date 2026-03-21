defmodule ElixirNexus.Search.Scoring do
  @moduledoc """
  Deduplication for hybrid search results.
  Keyword scoring and merging are now handled by Qdrant's native RRF fusion.
  """

  @doc """
  Deduplicate results with same name+entity_type, keeping highest score.
  """
  def deduplicate(results) do
    results
    |> Enum.group_by(fn r ->
      name = r.entity["name"] || ""
      type = r.entity["entity_type"] || ""
      "#{name}::#{type}"
    end)
    |> Enum.map(fn {_key, group} ->
      Enum.max_by(group, & &1.score)
    end)
  end
end
