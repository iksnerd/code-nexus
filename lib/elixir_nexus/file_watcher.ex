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
      # Not Process.exit(pid, :normal): that signal is ignored by a process that
      # isn't trapping exits, so the watcher kept running and kept indexing its
      # old directory into whatever collection was active next.
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _already_gone -> :ok
      end
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
  def handle_info({:file_event, _watcher_pid, {event_path, events}}, state) do
    case locate(event_path, state) do
      nil ->
        {:noreply, state}

      {root, path} ->
        cond do
          deleted?(events, event_path) ->
            # A deleted file, or a deleted or renamed-away directory: purge what
            # the index holds at or under the path, whatever the ignore rules
            # say now. No debounce needed.
            forget_deleted(path)
            {:noreply, %{state | pending: Map.delete(state.pending, path)}}

          ElixirNexus.FileScope.in_scope?(root, path) ->
            # Debounce: schedule flush, replacing any pending timer for same path
            Process.send_after(self(), {:flush, path}, @debounce_ms)
            {:noreply, %{state | pending: Map.put(state.pending, path, true)}}

          true ->
            {:noreply, state}
        end
    end
  end

  def handle_info({:file_event, _watcher_pid, :stop}, state) do
    Logger.info("FileWatcher stopped")
    {:noreply, state}
  end

  def handle_info({:flush, path}, state) do
    # Re-check at flush time: the watchers may have moved to another project
    # during the debounce window.
    if Map.has_key?(state.pending, path) and watched?(path, state) do
      reindex_if_dirty(path)
      {:noreply, %{state | pending: Map.delete(state.pending, path)}}
    else
      {:noreply, state}
    end
  end

  defp reindex_if_dirty(path) do
    case ElixirNexus.DirtyTracker.dirty?(path) do
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

  # Only act on paths under a directory currently being watched. Anything else
  # belongs to a project that is no longer active. Each root is matched both as
  # given and resolved, because FSEvents reports resolved paths (a watched
  # /var/... directory produces /private/var/... events on macOS). Returns the
  # root as given and the path rewritten under it, the form the index stores.
  defp locate(path, state) do
    state.watchers
    |> Map.keys()
    |> Enum.find_value(fn root ->
      root = String.trim_trailing(root, "/")

      [root, resolve_symlinks(root)]
      |> Enum.uniq()
      |> Enum.find_value(fn form ->
        cond do
          path == form -> {root, root}
          String.starts_with?(path, form <> "/") -> {root, root <> String.replace_prefix(path, form, "")}
          true -> nil
        end
      end)
    end)
  end

  defp watched?(path, state), do: locate(path, state) != nil

  defp resolve_symlinks(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce(fn segment, resolved ->
      candidate = Path.join(resolved, segment)

      case :file.read_link_all(candidate) do
        {:ok, target} -> Path.expand(to_string(target), resolved)
        _ -> candidate
      end
    end)
  end

  # The events name a removal and the path is gone from disk.
  defp deleted?(events, path) do
    Enum.any?(events, &(&1 in [:removed, :deleted, :renamed])) and not File.exists?(path)
  end

  defp forget_deleted(path) do
    prefix = path <> "/"

    indexed =
      (ElixirNexus.ChunkCache.file_paths() ++ ElixirNexus.DirtyTracker.known_files())
      |> Enum.uniq()
      |> Enum.filter(&(&1 == path or String.starts_with?(&1, prefix)))

    Enum.each(indexed, fn file ->
      Logger.info("File deleted, removing from index: #{file}")

      try do
        ElixirNexus.Indexer.delete_file(file)
      catch
        kind, reason -> Logger.warning("Failed to delete #{file} from index: #{inspect({kind, reason})}")
      end
    end)
  end
end
