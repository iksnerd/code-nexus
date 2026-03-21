defmodule ElixirNexus.FileWatcher do
  @moduledoc """
  Watches the filesystem for source file changes and triggers incremental re-indexing
  via DirtyTracker. Only re-indexes files whose content has actually changed.
  Debounces rapid saves to avoid redundant work.
  """
  use GenServer
  require Logger

  @debounce_ms 1000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def watch_directory(path) do
    GenServer.call(__MODULE__, {:watch, path})
  end

  def unwatch_all do
    GenServer.call(__MODULE__, :unwatch_all)
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  @impl true
  def init(_opts) do
    Logger.info("FileWatcher started")
    {:ok, %{watchers: %{}, pending: %{}}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{watching: map_size(state.watchers), pending: map_size(state.pending)}, state}
  end

  def handle_call(:unwatch_all, _from, state) do
    Enum.each(state.watchers, fn {path, pid} ->
      Logger.info("Unwatching directory: #{path}")
      Process.exit(pid, :normal)
    end)
    {:reply, :ok, %{state | watchers: %{}, pending: %{}}}
  end

  def handle_call({:watch, path}, _from, state) do
    case FileSystem.start_link(dirs: [path]) do
      {:ok, pid} ->
        FileSystem.subscribe(pid)
        Logger.info("Watching directory: #{path}")
        {:reply, {:ok, pid}, put_in(state, [:watchers, path], pid)}

      {:error, reason} ->
        Logger.error("Failed to watch #{path}: #{inspect(reason)}")
        {:reply, {:error, reason}, state}

      :ignore ->
        Logger.warning("File watcher ignored for #{path} (path may not exist in this environment)")
        {:reply, {:error, :ignored}, state}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, _events}}, state) do
    if indexable_file?(path) and not ignored_path?(path) do
      # Debounce: schedule flush, replacing any pending timer for same path
      new_pending = Map.put(state.pending, path, true)
      Process.send_after(self(), {:flush, path}, @debounce_ms)
      {:noreply, %{state | pending: new_pending}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, _watcher_pid, :stop}, state) do
    Logger.info("FileWatcher stopped")
    {:noreply, state}
  end

  def handle_info({:flush, path}, state) do
    if Map.has_key?(state.pending, path) do
      reindex_if_dirty(path)
      {:noreply, %{state | pending: Map.delete(state.pending, path)}}
    else
      {:noreply, state}
    end
  end

  defp reindex_if_dirty(path) do
    case ElixirNexus.DirtyTracker.is_dirty?(path) do
      {true, _checksum} ->
        Logger.info("File changed, re-indexing: #{path}")

        case ElixirNexus.Indexer.index_file(path) do
          {:ok, _chunks} ->
            ElixirNexus.DirtyTracker.mark_clean(path)
            ElixirNexus.Events.broadcast_file_reindexed(path)
            Logger.info("Re-indexed: #{path}")

          {:error, reason} ->
            Logger.warning("Failed to re-index #{path}: #{inspect(reason)}")
        end

      {false, _} ->
        :ok

      {:error, _} ->
        :ok
    end
  end

  defp indexable_file?(path) do
    ext = Path.extname(path)
    ext in [".ex", ".exs", ".js", ".jsx", ".ts", ".tsx", ".py", ".go", ".rs", ".java", ".rb"]
  end

  @ignored_dirs ~w(node_modules .next dist build .expo .turbo coverage __generated__ .cache vendor _build deps .elixir_ls .git)

  defp ignored_path?(path) do
    path
    |> Path.split()
    |> Enum.any?(fn segment -> segment in @ignored_dirs end)
  end
end
