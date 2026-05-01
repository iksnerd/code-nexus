defmodule ElixirNexus.MCPServer.IndexManagement do
  @moduledoc "Collection switching, dirty-file reindexing, and deletion cleanup."

  require Logger

  @doc """
  Switch Qdrant collection to match the project being indexed.

  Collection naming derives from the project name, not the container path.
  For single-project mounts (where project_root == /workspaceN), this avoids
  producing a useless `nexus_workspaceN` and instead names the collection
  after the user-supplied bare name or the host-side basename.
  """
  def ensure_collection_for_project(project_root, display_path \\ nil) do
    project_name = derive_project_name(project_root, display_path)

    collection =
      "nexus_#{project_name}"
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]/, "_")
      |> String.trim_leading("_")
      |> String.trim_trailing("_")
      |> String.slice(0..59)

    current = ElixirNexus.QdrantClient.active_collection()

    if collection != current do
      Logger.info("Switching Qdrant collection: #{current} -> #{collection}")
      ElixirNexus.QdrantClient.switch_collection_force(collection)
      ElixirNexus.Events.broadcast_collection_changed(collection)
    end
  end

  # Decide what to name a project's Qdrant collection.
  #
  # Priority order:
  #   1. display_path (the user's bare name like "council-hub") if it's a bare
  #      name (no slash) — that's the user's intent.
  #   2. project_root basename, unless it's a generic /workspace[N] mount root,
  #      in which case fall through.
  #   3. display_path basename (handles full host paths like "/Users/x/foo").
  #   4. project_root basename anyway (last resort).
  defp derive_project_name(project_root, display_path) do
    container_basename = Path.basename(project_root)
    looks_generic? = Regex.match?(~r/^workspace[0-9]*$/, container_basename) or container_basename in ["", ".", "_"]

    cond do
      is_binary(display_path) and display_path != "" and not String.contains?(display_path, "/") ->
        display_path

      not looks_generic? ->
        container_basename

      is_binary(display_path) and display_path != "" ->
        Path.basename(display_path)

      true ->
        container_basename
    end
  end

  @doc """
  Auto-reindex dirty files before queries to avoid stale results.
  Only runs if directories have been indexed (state has :indexed_dirs).
  Returns {reindexed_count, state} — state unchanged since dirs don't change.
  """
  def maybe_reindex_dirty(state) do
    dirs = Map.get(state, :indexed_dirs, [])

    if dirs == [] do
      {0, state}
    else
      case ElixirNexus.DirtyTracker.get_dirty_files_recursive(dirs) do
        {:ok, []} ->
          {0, state}

        {:ok, dirty_files} ->
          count = length(dirty_files)
          if count > 0, do: Logger.info("Auto-reindexing #{count} dirty file(s) before query")

          Enum.each(dirty_files, fn path ->
            case ElixirNexus.Indexer.index_file(path) do
              {:ok, _chunks} ->
                ElixirNexus.DirtyTracker.mark_clean(path)

              {:error, reason} ->
                Logger.warning("Auto-reindex failed for #{path}: #{inspect(reason)}")
            end
          end)

          # Clean up files that exist in cache but have been deleted from disk
          deleted_count = cleanup_deleted_files()

          {count + deleted_count, state}

        {:error, _} ->
          {0, state}
      end
    end
  end

  @doc """
  Remove cached chunks for files that no longer exist on disk.
  Catches deletions that happened while the server was down.
  """
  def cleanup_deleted_files do
    deleted_paths =
      try do
        ElixirNexus.ChunkCache.all()
        |> Enum.map(& &1.file_path)
        |> Enum.uniq()
        |> Enum.reject(&File.exists?/1)
      rescue
        _ -> []
      end

    Enum.each(deleted_paths, fn path ->
      Logger.info("Cleaning up deleted file from index: #{path}")
      ElixirNexus.Indexer.delete_file(path)
    end)

    length(deleted_paths)
  end

  @doc """
  Pin the active Qdrant collection into the process dictionary at the start of each
  tool call. QdrantClient.qdrant_state/0 checks this first, so concurrent reindex
  operations cannot swap the collection out from under an in-flight query.
  """
  def capture_collection do
    Process.put(:nexus_collection, ElixirNexus.QdrantClient.active_collection())
  end
end
