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
        chunks = Enum.map(points, &chunk_from_payload(to_string(&1["id"]), &1["payload"] || %{}))

        ChunkCache.insert_many(chunks)
        GraphCache.rebuild_from_chunks(chunks)

        # Rebuild TF-IDF vocabulary from chunk content so keyword search works without reindex
        texts = chunks |> Enum.map(& &1.content) |> Enum.reject(&(&1 == ""))
        if texts != [], do: ElixirNexus.TFIDFEmbedder.update_vocabulary(texts)

        # Seed DirtyTracker from stored file SHAs so the next reindex can skip
        # re-embedding unchanged files (survives container restarts).
        sha_map =
          Enum.reduce(points, %{}, fn p, acc ->
            payload = p["payload"] || %{}
            path = payload["file_path"]
            sha = payload["file_sha"]
            if is_binary(path) and is_binary(sha), do: Map.put(acc, path, sha), else: acc
          end)

        if map_size(sha_map) > 0, do: DirtyTracker.seed_from_map(sha_map)

        Logger.info("Reloaded #{length(chunks)} chunks from Qdrant into ETS caches (vocab: #{length(texts)} docs)")

      _ ->
        Logger.info("No points found in new collection")
    end
  end

  # Explicit whitelists, not String.to_existing_atom: that falls back silently
  # when the atom hasn't been created yet (modules load lazily under
  # `mix phx.server`), so a hydrated Python class came back as a :function with
  # no language. Bounded lists also keep Qdrant payloads from minting atoms.
  @entity_types Map.new(
                  ~w(function method module class struct interface variable constant enum macro test type),
                  &{&1, String.to_atom(&1)}
                )
  @languages Map.new(
               ~w(elixir go java javascript jsx kotlin python ruby rust swift tsx typescript),
               &{&1, String.to_atom(&1)}
             )
  @visibilities %{"public" => :public, "private" => :private}

  @doc "Build a ChunkCache chunk from a Qdrant point payload."
  def chunk_from_payload(id, payload) do
    %{
      id: id,
      entity_type: Map.get(@entity_types, payload["entity_type"], :function),
      name: payload["name"] || "",
      file_path: payload["file_path"] || "",
      content: payload["content"] || "",
      start_line: payload["start_line"] || 0,
      end_line: payload["end_line"] || 0,
      docstring: nil,
      module_path: payload["module_path"],
      visibility: Map.get(@visibilities, payload["visibility"]),
      parameters: payload["parameters"] || [],
      calls: payload["calls"] || [],
      is_a: payload["is_a"] || [],
      contains: payload["contains"] || [],
      language: Map.get(@languages, payload["language"])
    }
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
