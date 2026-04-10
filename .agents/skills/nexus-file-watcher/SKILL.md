---
name: nexus-file-watcher
description: ElixirNexus FileWatcher patterns — debounce, multi-directory watching, deletion vs modification handling, and integration with DirtyTracker. Use when modifying file watching behavior, adding new watched directories, understanding the debounce mechanism, or debugging file change events.
metadata:
  compatibility: ElixirNexus project only — lib/elixir_nexus/file_watcher.ex
---

# ElixirNexus FileWatcher

## Key File

`lib/elixir_nexus/file_watcher.ex` — GenServer that wraps the `file_system` library.

## State Shape

```elixir
%{
  watchers: %{path => watcher_pid},   # active FileSystem watchers per root dir
  pending:  %{file_path => timer_ref} # debounce timers per file
}
```

## Starting / Stopping Watchers

```elixir
# Watch a directory
FileWatcher.watch("/workspace/my-project/lib")

# Stop watching a directory
FileWatcher.unwatch("/workspace/my-project/lib")

# FileWatcher re-wires watchers when ProjectSwitcher changes collections
```

Internally:
```elixir
def handle_call({:watch, path}, _from, state) do
  {:ok, watcher_pid} = FileSystem.start_link(dirs: [path])
  FileSystem.subscribe(watcher_pid)
  {:reply, :ok, put_in(state.watchers[path], watcher_pid)}
end
```

## Debounce Mechanism

Rapid saves (e.g. editor auto-save) trigger multiple events. The debounce map prevents redundant reindexing:

```elixir
def handle_info({:file_event, _watcher, {path, events}}, state) do
  cond do
    deleted?(path, events) ->
      # No debounce — handle deletion immediately
      Indexer.delete_file(path)
      {:noreply, state}

    modified?(path, events) ->
      # Cancel existing timer for this path if any
      if ref = state.pending[path], do: Process.cancel_timer(ref)
      # Schedule reindex after 1000ms of quiet
      ref = Process.send_after(self(), {:reindex_file, path}, 1000)
      {:noreply, put_in(state.pending[path], ref)}
  end
end

def handle_info({:reindex_file, path}, state) do
  if File.exists?(path) do
    DirtyTracker.mark_dirty(path)
    Indexer.index_file(path)
  end
  {:noreply, update_in(state.pending, &Map.delete(&1, path))}
end
```

## Deletion vs Modification

The FileSystem library sends events as a list of atoms: `[:modified]`, `[:created]`, `[:removed]`, `[:deleted]`, `[:renamed]`.

```elixir
defp deleted?(path, events) do
  Enum.any?(events, & &1 in [:removed, :deleted]) and not File.exists?(path)
end

defp modified?(path, events) do
  Enum.any?(events, & &1 in [:modified, :created])
end
```

Always confirm deletion with `File.exists?/1` — some editors write a temp file then rename it, which can fire `:removed` events on the original name even though the file still exists under a new name.

## Integration with DirtyTracker

On file modification:
1. `FileWatcher` receives `:file_event`
2. Debounce timer fires after 1000ms
3. `DirtyTracker.mark_dirty(path)` — SHA256 mismatch will trigger reindex
4. `Indexer.index_file(path)` — fast single-file reindex

On file deletion:
1. `FileWatcher` receives `:file_event` with `:removed`/`:deleted`
2. `Indexer.delete_file(path)` — removes from ChunkCache, GraphCache, Qdrant, DirtyTracker

## Extending FileWatcher

To watch additional directories after initial setup (e.g. after `reindex` switches project):

```elixir
# Called by ProjectSwitcher after switching collection
FileWatcher.unwatch_all()
Enum.each(new_dirs, &FileWatcher.watch/1)
```

## Debugging File Events

```elixir
# Temporarily add logging in handle_info to see raw events
def handle_info({:file_event, _watcher, {path, events}}, state) do
  Logger.debug("File event: #{path} #{inspect(events)}")
  # ...
end
```

Common event sequences:
- Editor save: `[:modified]`
- Editor atomic save (write + rename): `[:created]` on temp, `[:renamed, :modified]` on original
- `rm file`: `[:removed]`
- `git checkout` on single file: `[:modified]`
