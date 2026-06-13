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

  @doc "Start indexing asynchronously — returns immediately. Poll get_status or use get_graph_stats to detect completion."
  def async_index_directories(paths) when is_list(paths) do
    GenServer.cast(__MODULE__, {:async_index_directories, paths})
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

  @doc """
  Wipe the current project's index: reset the Qdrant collection and clear the
  ChunkCache, GraphCache, and DirtyTracker. Leaves an empty index ready for a
  fresh reindex. Rejected while indexing is in progress.
  """
  def purge do
    GenServer.call(__MODULE__, :purge, :infinity)
  end

  @doc "Returns true when an indexing job is currently running."
  def busy? do
    status().status == :indexing
  end

  def search_chunks(query, limit \\ 10) do
    {:ok, ChunkCache.search(query, limit)}
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
        :idle ->
          :ok

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
      acked_file_count: 0,
      skip_stats: empty_skip_stats(),
      last_index_result: nil
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

    case collect_files(path) do
      {:ok, [], stats} ->
        clean_state = prepare_reindex(state)
        result = build_index_result(files: 0, skipped: stats, error: zero_files_error([path]))

        {:reply, {:ok, %{indexed_files: 0, total_chunks: 0, languages: [], skipped: stats}},
         %{clean_state | last_index_result: result}}

      {:ok, files, stats} ->
        do_index_files(files, stats, from, state)

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

    {all_files, combined_stats} =
      Enum.reduce(paths, {[], empty_skip_stats()}, fn path, {acc_files, acc_stats} ->
        case collect_files(path) do
          {:ok, files, stats} -> {acc_files ++ files, merge_skip_stats(acc_stats, stats)}
          {:error, _} -> {acc_files, acc_stats}
        end
      end)

    unique_files = Enum.uniq(all_files)

    case unique_files do
      [] ->
        clean_state = prepare_reindex(state)
        result = build_index_result(files: 0, skipped: combined_stats, error: zero_files_error(paths))

        {:reply, {:ok, %{indexed_files: 0, total_chunks: 0, languages: [], skipped: combined_stats}},
         %{clean_state | last_index_result: result}}

      files ->
        do_index_files(files, combined_stats, from, state)
    end
  end

  def handle_call({:index_file, file_path}, _from, state) do
    case File.exists?(file_path) do
      true ->
        Logger.info("Indexing file: #{file_path}")
        result = IndexingHelpers.process_file(file_path)

        new_state =
          case result do
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

  def handle_call(:purge, _from, %{status: :indexing} = state) do
    {:reply, {:error, :indexing_in_progress}, state}
  end

  def handle_call(:purge, _from, state) do
    Logger.info("Purging current collection and caches")
    clean_state = prepare_reindex(state)
    {:reply, :ok, %{clean_state | last_index_result: build_index_result(files: 0, error: nil)}}
  end

  def handle_call(:status, _from, state) do
    chunk_count =
      try do
        ChunkCache.count()
      rescue
        _ -> state.total_chunks
      end

    {:reply,
     %{
       indexed_files: MapSet.size(state.indexed_files),
       total_chunks: if(is_integer(chunk_count) and chunk_count > 0, do: chunk_count, else: state.total_chunks),
       status: state.status,
       errors: state.errors,
       indexing_progress: %{files_done: state.acked_file_count, total_files: state.pending_file_count},
       last_index_result: state.last_index_result
     }, state}
  end

  @impl true
  def handle_cast({:async_index_directories, _paths}, %{status: :indexing} = state) do
    {:noreply, state}
  end

  def handle_cast({:async_index_directories, paths}, state) do
    Logger.info("Starting async Broadway indexing of directories: #{inspect(paths)}")

    {all_files, combined_stats} =
      Enum.reduce(paths, {[], empty_skip_stats()}, fn path, {acc_files, acc_stats} ->
        case collect_files(path) do
          {:ok, files, stats} -> {acc_files ++ files, merge_skip_stats(acc_stats, stats)}
          {:error, _} -> {acc_files, acc_stats}
        end
      end)

    unique_files = Enum.uniq(all_files)

    case unique_files do
      [] ->
        Logger.warning("Async reindex resolved to 0 indexable files for #{inspect(paths)}")
        clean_state = prepare_reindex(state)

        result = build_index_result(files: 0, skipped: combined_stats, error: zero_files_error(paths))

        {:noreply, %{clean_state | last_index_result: result}}

      files ->
        do_async_index_files(files, combined_stats, state)
    end
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

  defp prepare_reindex(state) do
    case ElixirNexus.QdrantClient.reset_collection() do
      {:ok, _} -> Logger.info("Reset Qdrant collection before reindex")
      {:error, reason} -> Logger.warning("Failed to reset collection: #{inspect(reason)}")
    end

    ElixirNexus.DirtyTracker.reset()
    ChunkCache.clear()
    GraphCache.clear()

    %{
      state
      | indexed_files: MapSet.new(),
        total_chunks: 0,
        errors: [],
        pending_reply: nil,
        pending_file_count: 0,
        acked_file_count: 0,
        skip_stats: empty_skip_stats()
    }
  end

  # Async variant of do_index_files — no pending_reply, never issues a GenServer reply.
  defp do_async_index_files(files, skip_stats, state) do
    if ElixirNexus.DirtyTracker.empty?() do
      seed_dirty_tracker_from_qdrant()
    end

    if not ElixirNexus.DirtyTracker.empty?() do
      # Reconcile deletions first: files indexed in a previous pass that are no
      # longer in scope (deleted on disk, or newly excluded by .nexusignore) must
      # have their chunks/vectors/graph nodes purged — otherwise reindex is
      # additive and stale nodes persist.
      purged = purge_out_of_scope(files)

      dirty =
        Enum.filter(files, fn path ->
          case ElixirNexus.DirtyTracker.dirty?(path) do
            {true, _sha} -> true
            _ -> false
          end
        end)

      if dirty == [] do
        Logger.info("Incremental async reindex: all #{length(files)} files unchanged, #{purged} purged, skipping embed")

        result =
          build_index_result(
            files: length(files),
            chunks: ChunkCache.count(),
            languages: IndexingHelpers.count_languages(files),
            skipped: skip_stats
          )

        {:noreply, %{state | last_index_result: result}}
      else
        Logger.info(
          "Incremental async reindex: #{length(dirty)}/#{length(files)} files changed, re-embedding dirty only"
        )

        do_partial_reindex(dirty, files, skip_stats, nil, state)
      end
    else
      do_full_reindex(files, skip_stats, nil, state)
    end
  end

  defp do_index_files(files, skip_stats, from, state) do
    # On the first reindex after a container restart, DirtyTracker is empty even
    # though Qdrant already has vectors from the last session. Seed it now from the
    # stored file_sha values so the dirty check below can skip unchanged files.
    if ElixirNexus.DirtyTracker.empty?() do
      seed_dirty_tracker_from_qdrant()
    end

    # Fast path: if DirtyTracker was seeded from Qdrant (container restart with
    # existing data), check whether any files actually changed. If none did, the
    # existing Qdrant vectors and ETS caches are already correct — skip re-embedding.
    if not ElixirNexus.DirtyTracker.empty?() do
      purged = purge_out_of_scope(files)

      dirty =
        Enum.filter(files, fn path ->
          case ElixirNexus.DirtyTracker.dirty?(path) do
            {true, _sha} -> true
            _ -> false
          end
        end)

      if dirty == [] do
        Logger.info("Incremental reindex: all #{length(files)} files unchanged, #{purged} purged, skipping embed")

        result =
          build_index_result(
            files: length(files),
            chunks: ChunkCache.count(),
            languages: IndexingHelpers.count_languages(files),
            skipped: skip_stats
          )

        {:reply,
         {:ok,
          %{
            indexed_files: length(files),
            total_chunks: ChunkCache.count(),
            languages: IndexingHelpers.count_languages(files),
            skipped: skip_stats
          }}, %{state | last_index_result: result}}
      else
        Logger.info("Incremental reindex: #{length(dirty)}/#{length(files)} files changed, re-embedding dirty only")
        do_partial_reindex(dirty, files, skip_stats, from, state)
      end
    else
      do_full_reindex(files, skip_stats, from, state)
    end
  end

  defp do_full_reindex(files, skip_stats, from, state) do
    clean_state = prepare_reindex(state)
    ElixirNexus.IndexingProducer.push(files)

    {:noreply,
     %{
       clean_state
       | status: :indexing,
         indexed_files: MapSet.new(files),
         pending_reply: from,
         pending_file_count: length(files),
         acked_file_count: 0,
         skip_stats: skip_stats
     }}
  end

  # Partial reindex: only dirty files get re-embedded. Clean files keep their
  # existing Qdrant vectors and ETS entries. No collection reset.
  defp do_partial_reindex(dirty_files, all_files, skip_stats, from, state) do
    # Remove stale Qdrant points and ETS entries for each dirty file
    Enum.each(dirty_files, fn path ->
      ElixirNexus.QdrantClient.delete_points_by_file(path)
      ChunkCache.delete_by_file(path)
    end)

    ElixirNexus.IndexingProducer.push(dirty_files)

    clean_state = %{
      state
      | status: :indexing,
        indexed_files: MapSet.new(all_files),
        errors: [],
        pending_reply: from,
        pending_file_count: length(dirty_files),
        acked_file_count: 0,
        skip_stats: skip_stats
    }

    {:noreply, clean_state}
  end

  defp finish_indexing(state) do
    chunk_count = ChunkCache.count()
    file_count = MapSet.size(state.indexed_files)
    languages = IndexingHelpers.count_languages(MapSet.to_list(state.indexed_files))
    Logger.info("Broadway pipeline complete: #{file_count} files, #{chunk_count} chunks")

    # Rebuild graph cache asynchronously to avoid blocking the Indexer GenServer
    rebuild_graph_async()

    # Broadcast completion
    Events.broadcast_indexing_complete(%{files: file_count, chunks: chunk_count})

    result =
      build_index_result(
        files: file_count,
        chunks: chunk_count,
        languages: languages,
        skipped: state.skip_stats
      )

    new_state = %{
      state
      | total_chunks: chunk_count,
        status: :idle,
        pending_file_count: 0,
        acked_file_count: 0,
        last_index_result: result
    }

    # Reply to the waiting caller if there is one
    case new_state.pending_reply do
      nil ->
        {:noreply, new_state}

      from ->
        GenServer.reply(
          from,
          {:ok,
           %{
             indexed_files: file_count,
             total_chunks: chunk_count,
             languages: languages,
             skipped: state.skip_stats
           }}
        )

        {:noreply, %{new_state | pending_reply: nil}}
    end
  end

  # Collect all indexable files recursively. Returns the list of file paths
  # plus a skip-stats breakdown so the reindex response can report what was
  # filtered out and why.
  defp collect_files(path) do
    filter = IgnoreFilter.load(path)
    initial_stats = empty_skip_stats()

    case File.ls(path) do
      {:ok, entries} ->
        {files, stats} = collect_files_recursive(path, path, entries, filter, [], initial_stats)
        {:ok, files, stats}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_files_recursive(root_path, base_path, entries, filter, acc_files, acc_stats) do
    Enum.reduce(entries, {acc_files, acc_stats}, fn entry, {files, stats} ->
      full_path = Path.join(base_path, entry)

      cond do
        File.dir?(full_path) ->
          relative_path = Path.relative_to(full_path, root_path)

          case IgnoreFilter.classify_dir_path(relative_path, filter) do
            :include ->
              case File.ls(full_path) do
                {:ok, sub_entries} ->
                  collect_files_recursive(root_path, full_path, sub_entries, filter, files, stats)

                {:error, _} ->
                  {files, stats}
              end

            {:ignored, source} ->
              # A skipped directory contributes one count per source. We don't
              # walk the subtree to estimate file counts since that would defeat
              # the point of skipping it.
              {files, bump(stats, dir_key(source))}
          end

        true ->
          ext = Path.extname(entry)

          if indexable_extension?(ext) do
            case IgnoreFilter.classify_file(entry, filter) do
              :include -> {[full_path | files], stats}
              {:ignored, source} -> {files, bump(stats, file_key(source))}
            end
          else
            {files, bump(stats, :unsupported_extension)}
          end
      end
    end)
  end

  # Delete chunks/vectors/graph nodes for files that were indexed in a prior pass
  # but are no longer in the current scope (deleted on disk or newly ignored).
  # Returns the count of purged files. Keeps reindex reconciling rather than additive.
  defp purge_out_of_scope(in_scope_files) do
    scope_set = MapSet.new(in_scope_files)
    stale = Enum.reject(ElixirNexus.DirtyTracker.known_files(), &MapSet.member?(scope_set, &1))

    Enum.each(stale, fn path ->
      ElixirNexus.QdrantClient.delete_points_by_file(path)
      ChunkCache.delete_by_file(path)
      GraphCache.delete_by_file(path)
      ElixirNexus.DirtyTracker.forget(path)
    end)

    if stale != [], do: Logger.info("Reindex reconcile: purged #{length(stale)} out-of-scope files")
    length(stale)
  end

  # Rebuild the graph cache off-thread so the Indexer GenServer stays responsive.
  defp rebuild_graph_async do
    all_chunks = ChunkCache.all()

    Task.start(fn ->
      try do
        GraphCache.rebuild_from_chunks(all_chunks)
        Logger.info("Graph cache rebuilt (#{length(all_chunks)} chunks)")
      rescue
        e -> Logger.error("Failed to rebuild graph cache: #{inspect(e)}")
      end
    end)
  end

  # Build a terminal index-result record surfaced via get_status as last_index_result.
  # Lets callers distinguish "never ran" (nil) from "finished empty/errored" vs "finished ok".
  defp build_index_result(opts) do
    %{
      files: Keyword.get(opts, :files, 0),
      chunks: Keyword.get(opts, :chunks, 0),
      languages: Keyword.get(opts, :languages, []),
      skipped: Keyword.get(opts, :skipped, empty_skip_stats()),
      error: Keyword.get(opts, :error),
      finished_at: DateTime.utc_now()
    }
  end

  defp zero_files_error(paths) do
    "Indexed 0 files — the resolved path(s) #{inspect(paths)} contained no indexable source files " <>
      "(empty directory or wrong workspace mount). Try the full host path, or check that the project " <>
      "is mounted into the container."
  end

  defp empty_skip_stats do
    %{
      default_deny_dirs: 0,
      gitignore_dirs: 0,
      nexusignore_dirs: 0,
      default_deny_files: 0,
      gitignore_files: 0,
      nexusignore_files: 0,
      unsupported_extension: 0
    }
  end

  defp dir_key(:default), do: :default_deny_dirs
  defp dir_key(:gitignore), do: :gitignore_dirs
  defp dir_key(:nexusignore), do: :nexusignore_dirs

  defp file_key(:default), do: :default_deny_files
  defp file_key(:gitignore), do: :gitignore_files
  defp file_key(:nexusignore), do: :nexusignore_files

  defp bump(stats, key), do: Map.update!(stats, key, &(&1 + 1))

  defp merge_skip_stats(a, b) do
    Map.merge(a, b, fn _, va, vb -> va + vb end)
  end

  defp indexable_extension?(ext) do
    ext in IndexingHelpers.elixir_extensions() or
      Map.has_key?(IndexingHelpers.polyglot_extensions(), ext)
  end

  # Scroll Qdrant for file_sha values and seed DirtyTracker.
  # Lightweight: reads payload metadata only, no embeddings or cache rebuilds.
  defp seed_dirty_tracker_from_qdrant do
    sha_map = collect_file_shas(nil, %{})

    if map_size(sha_map) > 0 do
      ElixirNexus.DirtyTracker.seed_from_map(sha_map)
    end
  end

  defp collect_file_shas(offset, acc) do
    case ElixirNexus.QdrantClient.scroll_points(200, offset) do
      {:ok, %{"result" => %{"points" => points, "next_page_offset" => next}}}
      when is_list(points) and points != [] ->
        new_acc =
          Enum.reduce(points, acc, fn p, a ->
            path = get_in(p, ["payload", "file_path"])
            sha = get_in(p, ["payload", "file_sha"])
            if is_binary(path) and is_binary(sha), do: Map.put(a, path, sha), else: a
          end)

        if next, do: collect_file_shas(next, new_acc), else: new_acc

      _ ->
        acc
    end
  end
end
