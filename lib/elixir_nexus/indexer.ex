defmodule ElixirNexus.Indexer do
  @moduledoc """
  Parallel indexing pipeline: parse -> chunk -> embed -> store.
  Bulk indexing uses Broadway for back-pressure and auto-batching.
  Single-file reindex remains synchronous for fast FileWatcher response.
  """
  use GenServer
  require Logger

  alias ElixirNexus.{ChunkCache, GraphCache, Events, IgnoreFilter, IndexingHelpers}

  @max_concurrency System.schedulers_online()

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def index_directory(path) do
    GenServer.call(__MODULE__, {:index_directory, path}, :infinity)
  end

  def index_directories(paths) when is_list(paths) do
    GenServer.call(__MODULE__, {:index_directories, paths}, :infinity)
  end

  def index_file(file_path) do
    GenServer.call(__MODULE__, {:index_file, file_path}, :infinity)
  end

  @doc "Remove a deleted file from all caches and Qdrant."
  def delete_file(file_path) do
    GenServer.call(__MODULE__, {:delete_file, file_path}, :infinity)
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  def search_chunks(query, limit \\ 10) do
    GenServer.call(__MODULE__, {:search_chunks, query, limit})
  end

  @doc """
  Block until the indexer becomes idle, or timeout after `timeout_ms` milliseconds.
  Returns `:ok` when idle, or `{:error, :timeout}` if still indexing.
  Useful for tests and callers that need to wait for a previous indexing run to finish.
  """
  def await_idle(timeout_ms \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_idle(deadline)
  end

  defp do_await_idle(deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :timeout}
    else
      case status().status do
        :idle -> :ok
        _ ->
          Process.sleep(100)
          do_await_idle(deadline)
      end
    end
  end

  @impl true
  def init(_opts) do
    Logger.info("Indexer started (Broadway pipeline, concurrency: #{@max_concurrency})")

    state = %{
      indexed_files: MapSet.new(),
      total_chunks: 0,
      status: :idle,
      errors: [],
      pending_reply: nil,
      pending_file_count: 0,
      acked_file_count: 0
    }

    if ChunkCache.count() > 0 do
      Task.start(fn ->
        try do
          GraphCache.rebuild_from_chunks(ChunkCache.all())
          Logger.info("Graph cache rebuilt at startup")
        rescue
          e -> Logger.error("Failed to rebuild graph cache at startup: #{inspect(e)}")
        end
      end)
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:index_directory, _path}, _from, %{status: :indexing} = state) do
    {:reply, {:error, :indexing_in_progress}, state}
  end

  def handle_call({:index_directory, path}, from, state) do
    Logger.info("Starting Broadway indexing of directory: #{path}")

    case ElixirNexus.QdrantClient.reset_collection() do
      {:ok, _} -> Logger.info("Reset Qdrant collection before reindex")
      {:error, reason} -> Logger.warning("Failed to reset collection: #{inspect(reason)}")
    end

    # Reset dirty tracker and ETS caches
    ElixirNexus.DirtyTracker.reset()
    ChunkCache.clear()
    GraphCache.clear()

    clean_state = %{state | indexed_files: MapSet.new(), total_chunks: 0, errors: [], pending_reply: nil, pending_file_count: 0, acked_file_count: 0}

    case collect_files(path) do
      {:ok, files} when files != [] ->
        # Push files to Broadway pipeline
        ElixirNexus.IndexingProducer.push(files)

        # Track completion: wait for acks from pipeline batchers
        {:noreply, %{clean_state |
          status: :indexing,
          indexed_files: MapSet.new(files),
          pending_reply: from,
          pending_file_count: length(files),
          acked_file_count: 0
        }}

      {:ok, []} ->
        {:reply, {:ok, %{indexed_files: 0, total_chunks: 0}}, clean_state}

      {:error, reason} ->
        Logger.error("Failed to read directory #{path}: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:index_directories, _paths}, _from, %{status: :indexing} = state) do
    {:reply, {:error, :indexing_in_progress}, state}
  end

  def handle_call({:index_directories, paths}, from, state) do
    Logger.info("Starting Broadway indexing of directories: #{inspect(paths)}")

    case ElixirNexus.QdrantClient.reset_collection() do
      {:ok, _} -> Logger.info("Reset Qdrant collection before reindex")
      {:error, reason} -> Logger.warning("Failed to reset collection: #{inspect(reason)}")
    end

    ElixirNexus.DirtyTracker.reset()
    ChunkCache.clear()
    GraphCache.clear()

    clean_state = %{state | indexed_files: MapSet.new(), total_chunks: 0, errors: [], pending_reply: nil, pending_file_count: 0, acked_file_count: 0}

    all_files =
      paths
      |> Enum.flat_map(fn path ->
        case collect_files(path) do
          {:ok, files} -> files
          {:error, _} -> []
        end
      end)
      |> Enum.uniq()

    case all_files do
      [] ->
        {:reply, {:ok, %{indexed_files: 0, total_chunks: 0}}, clean_state}

      files ->
        ElixirNexus.IndexingProducer.push(files)

        {:noreply, %{clean_state |
          status: :indexing,
          indexed_files: MapSet.new(files),
          pending_reply: from,
          pending_file_count: length(files),
          acked_file_count: 0
        }}
    end
  end

  def handle_call({:index_file, file_path}, _from, state) do
    case File.exists?(file_path) do
      true ->
        Logger.info("Indexing file: #{file_path}")
        result = IndexingHelpers.process_file(file_path)

        new_state = case result do
          {:ok, chunks} ->
            # Embed and store synchronously (fast path for single file)
            IndexingHelpers.embed_and_store(chunks)

            # Update ETS caches
            ChunkCache.delete_by_file(file_path)
            ChunkCache.insert_many(chunks)
            GraphCache.update_file(file_path, chunks)

            # Broadcast file reindex event
            Events.broadcast_file_reindexed(file_path)

            %{
              state
              | indexed_files: MapSet.put(state.indexed_files, file_path),
                total_chunks: state.total_chunks + length(chunks)
            }

          {:error, _} ->
            %{state | indexed_files: MapSet.put(state.indexed_files, file_path)}
        end

        {:reply, result, new_state}

      false ->
        Logger.error("File not found: #{file_path}")
        {:reply, {:error, :enoent}, state}
    end
  end

  def handle_call({:delete_file, file_path}, _from, state) do
    Logger.info("Deleting file from index: #{file_path}")
    ChunkCache.delete_by_file(file_path)
    GraphCache.delete_by_file(file_path)

    try do
      ElixirNexus.QdrantClient.delete_points_by_file(file_path)
    rescue
      e -> Logger.warning("Failed to delete Qdrant points for #{file_path}: #{inspect(e)}")
    end

    ElixirNexus.DirtyTracker.forget(file_path)
    Events.broadcast_file_deleted(file_path)

    new_state = %{state | indexed_files: MapSet.delete(state.indexed_files, file_path)}
    {:reply, :ok, new_state}
  end

  def handle_call(:status, _from, state) do
    chunk_count = try do
      ChunkCache.count()
    rescue
      _ -> state.total_chunks
    end

    {:reply,
     %{
       indexed_files: MapSet.size(state.indexed_files),
       total_chunks: if(is_integer(chunk_count) and chunk_count > 0, do: chunk_count, else: state.total_chunks),
       status: state.status,
       errors: state.errors
     }, state}
  end

  def handle_call({:search_chunks, query, limit}, _from, state) do
    # Delegate to ETS-backed ChunkCache
    results = ChunkCache.search(query, limit)
    {:reply, {:ok, results}, state}
  end

  @impl true
  def handle_info({:file_indexed, file_path, chunk_count}, state) do
    acked = Map.get(state, :acked_file_count, 0) + 1
    total = state.pending_file_count
    Logger.info("Indexer: ack #{acked}/#{total} for #{Path.basename(file_path)} (#{chunk_count} chunks)")

    new_state = Map.put(state, :acked_file_count, acked)

    if acked >= total and total > 0 do
      finish_indexing(new_state)
    else
      {:noreply, new_state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp finish_indexing(state) do
    chunk_count = ChunkCache.count()
    file_count = MapSet.size(state.indexed_files)
    Logger.info("Broadway pipeline complete: #{file_count} files, #{chunk_count} chunks")

    # Rebuild graph cache asynchronously to avoid blocking the Indexer GenServer
    all_chunks = ChunkCache.all()
    Task.start(fn ->
      try do
        GraphCache.rebuild_from_chunks(all_chunks)
        Logger.info("Graph cache rebuilt (#{length(all_chunks)} chunks)")
      rescue
        e -> Logger.error("Failed to rebuild graph cache: #{inspect(e)}")
      end
    end)

    # Broadcast completion
    Events.broadcast_indexing_complete(%{files: file_count, chunks: chunk_count})

    new_state = %{state |
      total_chunks: chunk_count,
      status: :idle,
      pending_file_count: 0,
      acked_file_count: 0
    }

    # Reply to the waiting caller if there is one
    case new_state.pending_reply do
      nil ->
        {:noreply, new_state}

      from ->
        GenServer.reply(from, {:ok, %{indexed_files: file_count, total_chunks: chunk_count}})
        {:noreply, %{new_state | pending_reply: nil}}
    end
  end

  # Collect all indexable files recursively
  defp collect_files(path) do
    filter = IgnoreFilter.load(path)

    case File.ls(path) do
      {:ok, entries} ->
        files = collect_files_recursive(path, entries, filter)
        {:ok, files}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_files_recursive(base_path, entries, filter) do
    Enum.flat_map(entries, fn entry ->
      full_path = Path.join(base_path, entry)

      if File.dir?(full_path) do
        if IgnoreFilter.ignored_dir?(entry, filter) do
          []
        else
          case File.ls(full_path) do
            {:ok, sub_entries} -> collect_files_recursive(full_path, sub_entries, filter)
            {:error, _} -> []
          end
        end
      else
        ext = Path.extname(entry)
        if indexable_extension?(ext), do: [full_path], else: []
      end
    end)
  end

  defp indexable_extension?(ext) do
    ext in IndexingHelpers.elixir_extensions() or
      Map.has_key?(IndexingHelpers.polyglot_extensions(), ext)
  end
end
