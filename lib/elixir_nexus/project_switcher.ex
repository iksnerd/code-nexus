defmodule ElixirNexus.ProjectSwitcher do
  @moduledoc "Coordinates switching between Qdrant collections (projects)."
  require Logger

  alias ElixirNexus.{QdrantClient, GraphCache, ChunkCache, DirtyTracker, Events}

  def switch_project(collection_name) do
    Logger.info("Switching to collection: #{collection_name}")

    case QdrantClient.switch_collection(collection_name) do
      :ok ->
        ChunkCache.clear()
        GraphCache.clear()
        DirtyTracker.reset()

        # Reload ETS caches from the new Qdrant collection
        reload_caches_from_qdrant()

        Events.broadcast_collection_changed(collection_name)
        :ok

      {:error, reason} ->
        Logger.error("Failed to switch collection: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "Reload ETS caches (ChunkCache + GraphCache) from the active Qdrant collection."
  def reload_from_qdrant do
    reload_caches_from_qdrant()
  end

  defp reload_caches_from_qdrant do
    # Clear ETS before reloading to avoid duplicates (ChunkCache is :bag type)
    ChunkCache.clear()
    GraphCache.clear()

    # Scroll all points from Qdrant and rebuild ETS caches
    case scroll_all(100, nil, []) do
      {:ok, points} when points != [] ->
        chunks =
          Enum.map(points, fn p ->
            payload = p["payload"] || %{}

            %{
              id: to_string(p["id"]),
              entity_type: safe_to_atom(payload["entity_type"], :function),
              name: payload["name"] || "",
              file_path: payload["file_path"] || "",
              content: payload["content"] || "",
              start_line: payload["start_line"] || 0,
              end_line: payload["end_line"] || 0,
              docstring: nil,
              module_path: payload["module_path"],
              visibility: payload["visibility"] && safe_to_atom(payload["visibility"], nil),
              parameters: payload["parameters"] || [],
              calls: payload["calls"] || [],
              is_a: payload["is_a"] || [],
              contains: payload["contains"] || [],
              language: payload["language"] && safe_to_atom(payload["language"], nil)
            }
          end)

        ChunkCache.insert_many(chunks)
        GraphCache.rebuild_from_chunks(chunks)

        # Rebuild TF-IDF vocabulary from chunk content so keyword search works without reindex
        texts = chunks |> Enum.map(& &1.content) |> Enum.reject(&(&1 == ""))
        if texts != [], do: ElixirNexus.TFIDFEmbedder.update_vocabulary(texts)

        Logger.info("Reloaded #{length(chunks)} chunks from Qdrant into ETS caches (vocab: #{length(texts)} docs)")

      _ ->
        Logger.info("No points found in new collection")
    end
  end

  defp safe_to_atom(nil, default), do: default

  defp safe_to_atom(str, default) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> default
  end

  # Use list prepend + reverse to avoid O(n^2) list append
  defp scroll_all(page_size, offset, acc) do
    case QdrantClient.scroll_points(page_size, offset) do
      {:ok, %{"result" => %{"points" => points, "next_page_offset" => next}}}
      when is_list(points) and points != [] ->
        new_acc = Enum.reverse(points) ++ acc
        if next, do: scroll_all(page_size, next, new_acc), else: {:ok, Enum.reverse(new_acc)}

      {:ok, %{"result" => %{"points" => points}}} when is_list(points) ->
        {:ok, Enum.reverse(Enum.reverse(points) ++ acc)}

      _ ->
        {:ok, Enum.reverse(acc)}
    end
  end
end
