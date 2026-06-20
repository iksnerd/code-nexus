defmodule ElixirNexus.Search.DataFetching do
  @moduledoc "Loads entities from ChunkCache (fast) or Qdrant scroll (fallback)."

  # The ChunkCache path is already fully in memory, so the `limit` only bounds the Qdrant
  # scroll fallback. Callers like find_dead_code / community_context need EVERY entity to
  # build a complete call index — truncating there silently dropped call edges on any
  # project over the cap (e.g. control-stack: 2247 chunks) and produced false dead-code
  # positives. Pass :all to take everything; the cap stays only as a scroll-page bound.
  def get_all_entities_cached(limit) do
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
              # All collection-shape fields use Map.get to tolerate older chunks
              # missing optional keys — relevant after a schema bump or for
              # test fixtures built before a field was added.
              "parameters" => Map.get(chunk, :parameters, []),
              "calls" => Map.get(chunk, :calls, []) || [],
              "is_a" => Map.get(chunk, :is_a, []) || [],
              "contains" => Map.get(chunk, :contains, []) || [],
              "content" => chunk.content,
              "language" => chunk[:language] && to_string(chunk[:language])
            }
          }
        end)

      # ChunkCache is fully in memory — never truncate it. `:all` keeps every entity; a
      # numeric limit is still honored for callers that explicitly want a bound.
      case limit do
        :all -> {:ok, entities}
        n when is_integer(n) -> {:ok, Enum.take(entities, n)}
        _ -> {:ok, entities}
      end
    else
      # Fallback to Qdrant scroll — slow for large collections
      get_all_entities(scroll_limit(limit))
    end
  end

  # Qdrant scroll needs a concrete upper bound. `:all` maps to a large ceiling.
  defp scroll_limit(:all), do: 100_000
  defp scroll_limit(n) when is_integer(n), do: n
  defp scroll_limit(_), do: 100_000

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
