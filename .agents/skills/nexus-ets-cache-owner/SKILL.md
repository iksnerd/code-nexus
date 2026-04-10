---
name: nexus-ets-cache-owner
description: ElixirNexus ETS cache architecture — CacheOwner process, ChunkCache and GraphCache design, table ownership semantics, and access patterns. Use when modifying cache behavior, adding new cached data, debugging ETS table errors, or understanding why cache tables survive GenServer crashes.
metadata:
  compatibility: ElixirNexus project only
---

# ElixirNexus ETS Cache Architecture

## Key Files

| File | Role |
|---|---|
| `lib/elixir_nexus/cache_owner.ex` | Creates and owns ETS tables for their lifetime |
| `lib/elixir_nexus/chunk_cache.ex` | :bag — file → [chunks] mapping |
| `lib/elixir_nexus/graph_cache.ex` | :set — entity_id → node mapping |

## Why CacheOwner?

ETS tables are owned by the process that creates them. If that process crashes, the table is deleted. To make tables survive crashes of downstream processes (Indexer, Pipeline), a dedicated `CacheOwner` GenServer owns them:

```
Supervisor (rest_for_one)
  ├── Registry
  ├── CacheOwner      ← creates + owns ETS tables
  ├── QdrantClient
  ├── Indexer         ← reads/writes ETS; if it crashes, tables survive
  ├── IndexingPipeline
  └── FileWatcher
```

If `Indexer` crashes and restarts, the ETS data is intact — only Indexer's GenServer state resets.

## ChunkCache — :bag Table

```elixir
# Table: :nexus_chunk_cache
# Type: :bag — multiple values per key (file path → many chunks)
# Options: :public, read_concurrency: true, write_concurrency: true

# Store chunks for a file (batch insert)
entries = Enum.map(chunks, fn chunk -> {file_path, chunk} end)
:ets.insert(:nexus_chunk_cache, entries)

# Get all chunks for a file
chunks = :ets.lookup(:nexus_chunk_cache, file_path)
         |> Enum.map(fn {_path, chunk} -> chunk end)

# Delete all chunks for a file (on reindex or deletion)
:ets.delete(:nexus_chunk_cache, file_path)

# Get first N chunks across all files (early-exit scan)
results =
  :ets.foldl(
    fn {_path, chunk}, acc ->
      if length(acc) < limit, do: [chunk | acc], else: acc
    end,
    [],
    :nexus_chunk_cache
  )
```

## GraphCache — :set Table

```elixir
# Table: :nexus_graph_cache
# Type: :set — one node per entity_id
# Options: :public, read_concurrency: true, write_concurrency: true

# Store a node
:ets.insert(:nexus_graph_cache, {entity_id, node})

# Lookup a node
case :ets.lookup(:nexus_graph_cache, entity_id) do
  [{^entity_id, node}] -> {:ok, node}
  []                   -> :miss
end

# Get all nodes (for graph traversal)
nodes = :ets.foldl(fn {_id, node}, acc -> [node | acc] end, [], :nexus_graph_cache)

# Clear graph (before rebuild)
:ets.delete_all_objects(:nexus_graph_cache)
```

## TFIDFEmbedder — Hybrid Read/Write Pattern

`TFIDFEmbedder` stores IDF values in a separate ETS table with a GenServer serializing writes but allowing direct concurrent reads:

```elixir
# Table: :nexus_tfidf_idf (set, public, read_concurrency: true)

# Writes — go through GenServer (serialized, consistent)
TFIDFEmbedder.update_vocabulary(documents)

# Reads — go directly to ETS (concurrent, no bottleneck)
idf = case :ets.lookup(:nexus_tfidf_idf, word) do
  [{^word, idf}] -> idf
  []             -> 0.0
end
```

## Adding a New Cache

1. Create the table in `CacheOwner.init/1` alongside existing tables
2. Create a wrapper module (e.g. `lib/elixir_nexus/my_cache.ex`) with typed access functions
3. Add cleanup to `Indexer.delete_file/1` if the cache is file-keyed
4. Use `:bag` for one-to-many, `:set` for one-to-one

## Supervision Order Matters

In `application.ex`, `CacheOwner` must start **before** any process that reads or writes the tables. The `rest_for_one` strategy ensures that if `CacheOwner` crashes, all downstream processes (Indexer, Pipeline, FileWatcher) restart too — preventing them from operating against a deleted table.

```elixir
children = [
  {Registry, ...},
  MyApp.CacheOwner,    # ← must be before Indexer
  MyApp.QdrantClient,
  MyApp.Indexer,       # ← safe to start after CacheOwner
  ...
]
Supervisor.start_link(children, strategy: :rest_for_one)
```
