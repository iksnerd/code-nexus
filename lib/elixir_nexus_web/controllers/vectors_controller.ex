defmodule ElixirNexus.API.VectorsController do
  use Phoenix.Controller

  def info(conn, _params) do
    case ElixirNexus.QdrantClient.collection_info() do
      {:ok, data} ->
        result = data["result"]

        json(conn, %{
          success: true,
          data: %{
            status: result["status"],
            points_count: result["points_count"],
            vectors_count: result["vectors_count"],
            segments_count: length(result["segments"] || []),
            config: result["config"]
          }
        })

      {:error, reason} ->
        json(conn, %{success: false, error: inspect(reason)})
    end
  end

  def count(conn, params) do
    filter = build_filter(params)

    case ElixirNexus.QdrantClient.count_points(filter) do
      {:ok, data} ->
        json(conn, %{success: true, data: %{count: data["result"]["count"]}})

      {:error, reason} ->
        json(conn, %{success: false, error: inspect(reason)})
    end
  end

  def scroll(conn, params) do
    limit = Map.get(params, "limit", 20)
    offset = Map.get(params, "offset")
    filter = build_filter(params)

    case ElixirNexus.QdrantClient.scroll_points(limit, offset, filter) do
      {:ok, data} ->
        points =
          (data["result"]["points"] || [])
          |> Enum.map(fn point ->
            %{
              id: point["id"],
              payload: point["payload"]
            }
          end)

        json(conn, %{
          success: true,
          data: %{
            points: points,
            next_offset: data["result"]["next_page_offset"]
          }
        })

      # Collection not yet created (e.g. fresh boot before any reindex). Return an
      # empty scroll instead of a 500 — the question "what points exist?" has a
      # legitimate answer of "none" when there is no collection.
      {:error, {404, _}} ->
        json(conn, %{success: true, data: %{points: [], next_offset: nil}})

      {:error, reason} ->
        json(conn, %{success: false, error: inspect(reason)})
    end
  end

  def get(conn, %{"id" => id}) do
    parsed_id = parse_id(id)

    case ElixirNexus.QdrantClient.get_point(parsed_id) do
      {:ok, data} ->
        point = data["result"]

        vector_preview =
          case point["vector"] do
            v when is_list(v) -> Enum.take(v, 10)
            _ -> []
          end

        json(conn, %{
          success: true,
          data: %{
            id: point["id"],
            payload: point["payload"],
            vector_preview: vector_preview
          }
        })

      {:error, reason} ->
        json(conn, %{success: false, error: inspect(reason)})
    end
  end

  def delete(conn, %{"ids" => ids}) when is_list(ids) do
    parsed_ids = Enum.map(ids, &parse_id/1)

    case ElixirNexus.QdrantClient.delete_points(parsed_ids) do
      {:ok, _} ->
        json(conn, %{success: true, data: %{deleted: length(parsed_ids)}})

      {:error, reason} ->
        json(conn, %{success: false, error: inspect(reason)})
    end
  end

  def reset(conn, _params) do
    case ElixirNexus.QdrantClient.reset_collection() do
      {:ok, _} ->
        json(conn, %{success: true, data: %{message: "Collection reset successfully"}})

      {:error, reason} ->
        json(conn, %{success: false, error: inspect(reason)})
    end
  end

  defp build_filter(%{"entity_type" => type}) do
    %{"must" => [%{"key" => "entity_type", "match" => %{"value" => type}}]}
  end

  defp build_filter(%{"file_path" => path}) do
    %{"must" => [%{"key" => "file_path", "match" => %{"value" => path}}]}
  end

  defp build_filter(_), do: nil

  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> id
    end
  end
end
