---
name: nexus-indexing-pipeline
description: ElixirNexus indexing pipeline architecture — Broadway pipeline, DirtyTracker SHA256 incremental indexing, Indexer GenServer, and auto-reindex flow. Use when modifying indexing behavior, understanding how files are tracked, adding new language support, or debugging indexing failures.
metadata:
  compatibility: ElixirNexus project only
---

# ElixirNexus Indexing Pipeline

## Key Files

| File | Role |
|---|---|
| `lib/elixir_nexus/indexer.ex` | Central coordinator GenServer |
| `lib/elixir_nexus/indexing_pipeline.ex` | Broadway pipeline (parse → embed → store) |
| `lib/elixir_nexus/indexing_producer.ex` | GenStage producer (demand-driven queue) |
| `lib/elixir_nexus/dirty_tracker.ex` | SHA256-based incremental change detection |
| `lib/elixir_nexus/indexing_helpers.ex` | File processing, embedding, Qdrant storage |

## Data Flow

```
Indexer.index_directories([paths])
  → IndexingProducer.push(file_paths)
    → Broadway Processor (per file, concurrent):
        TreeSitterParser.parse(file)
        → extract entities + call graph
        → emit telemetry :file_parsed
        → put_batcher(:embed_and_store)
    → Broadway Batcher (batch_size: 32, timeout: 1000ms):
        EmbeddingModel.embed(chunks)   # Ollama embeddinggemma:300m (default; OLLAMA_MODEL env var)
        → QdrantClient.upsert_points
        → ChunkCache.insert_chunks
        → RelationshipGraph rebuild (async)
        → Events.broadcast(:indexing_progress)
  → Indexer marks complete → Events.broadcast(:indexing_complete)
```

## Incremental Indexing (DirtyTracker)

DirtyTracker uses SHA256 to detect changed files — only reindexes files that actually changed:

```elixir
# Mark file dirty (file watcher calls this on change)
DirtyTracker.mark_dirty(file_path)

# Check for dirty files in indexed directories
dirty_files = DirtyTracker.get_dirty_files_recursive(indexed_dirs)

# After successful indexing, mark clean
DirtyTracker.mark_clean(file_path)
```

Files are "dirty" when their current SHA256 differs from the stored hash. All dirty files are reindexed by query tools before executing — results are always fresh.

## Concurrency Safety

Only one `index_directories` / `index_directories` call can run at a time:

```elixir
# Concurrent calls are rejected
case Indexer.index_directories(paths) do
  :ok -> :indexed
  {:error, :indexing_in_progress} ->
    # Already running — wait or notify user
end
```

Check `Indexer.status()` to see current state: `:idle`, `:indexing`, or `:awaiting_idle`.

## Single-File Reindex (Fast Path)

For incremental updates, prefer `index_file/1` over full `index_directories/1`:

```elixir
# Fast — reindexes one file, updates graph incrementally
Indexer.index_file("lib/my_module.ex")
```

Used by: FileWatcher on changes, query tools auto-reindex, `maybe_reindex_dirty/1`.

## File Deletion

When a file is deleted, call `Indexer.delete_file/1` to clean up across all stores:

```elixir
Indexer.delete_file(path)
# Orchestrates: ChunkCache.delete + GraphCache.delete + Qdrant.delete_points + DirtyTracker.mark_clean
```

FileWatcher calls this on `:removed`/`:deleted` events. The `maybe_reindex_dirty/1` pass also checks for files in ChunkCache that no longer exist on disk.

## Graph Rebuild

After indexing, graph rebuild is **async** (non-blocking):

```elixir
# Called internally after batch processing completes
Task.start(fn -> RelationshipGraph.rebuild() end)
```

Don't wait on graph rebuild before responding to MCP queries — use the current graph state.

## Adding Language Support

1. Add a parser module in `lib/elixir_nexus/parsers/<lang>_extractor.ex`
2. Add extension mapping in `lib/elixir_nexus/tree_sitter_parser.ex` `@extension_map`
3. If tree-sitter grammar needed: update `native/tree_sitter_nif/src/lib.rs` and rebuild NIF
4. Update `is_significant_node()` in Rust if new AST node types are needed

## Multi-Project Support

Each project gets its own Qdrant collection (`nexus_<project_name>`). Switching projects:

```elixir
ProjectSwitcher.switch_to("my-project")
# Switches Qdrant collection, reloads ETS from Qdrant, re-wires FileWatcher
```

The `reindex` MCP tool auto-detects project name from path and switches collections.
