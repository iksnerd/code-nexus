defmodule ElixirNexus.Search.DataFetching do
  @moduledoc "Loads entities from ChunkCache (fast) or Qdrant scroll (fallback)."

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
