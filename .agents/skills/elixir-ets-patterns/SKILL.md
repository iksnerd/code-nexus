---
name: elixir-ets-patterns
description: ETS (Erlang Term Storage) patterns for in-process shared memory. Use when implementing a cache, shared in-memory storage, lookup table, or high-throughput read store. Covers table types, concurrency options, ownership, and common operations including foldl, match, and select.
metadata:
  source: hexdocs.pm/elixir/:ets + ElixirNexus codebase patterns
  docs: https://www.erlang.org/doc/apps/stdlib/ets.html
---

# ETS Patterns

## Table Types

| Type | Keys | Values | Use for |
|---|---|---|---|
| `:set` | Unique | One per key | Key-value cache |
| `:ordered_set` | Unique, sorted | One per key | Sorted lookups |
| `:bag` | Duplicate keys allowed | Many per key | One-to-many (e.g. file → [chunks]) |
| `:duplicate_bag` | Duplicate key+value | Many per key | Rarely needed |

## Creating Tables

```elixir
# Basic set
table = :ets.new(:my_cache, [:set, :public])

# Optimized for concurrent reads (most common for caches)
table = :ets.new(:my_cache, [
  :set,
  :public,
  read_concurrency: true,
  write_concurrency: true
])

# Named table (accessible by atom without storing ref)
:ets.new(:my_cache, [:set, :public, :named_table])

# Bag for one-to-many relationships
table = :ets.new(:chunks, [:bag, :public, read_concurrency: true])
```

## Basic Operations

```elixir
# Insert
:ets.insert(:my_cache, {key, value})

# Batch insert (faster than individual inserts)
entries = Enum.map(items, fn item -> {item.id, item} end)
:ets.insert(:my_cache, entries)

# Lookup (returns list of tuples)
case :ets.lookup(:my_cache, key) do
  [{^key, value}] -> {:ok, value}
  []              -> :miss
end

# Delete
:ets.delete(:my_cache, key)

# Delete all
:ets.delete_all_objects(:my_cache)

# Count entries
:ets.info(:my_cache, :size)
```

## Efficient Traversal with foldl

For scanning with early exit or filtering without copying the whole table to heap:

```elixir
# Collect up to 100 items matching a predicate
results =
  :ets.foldl(
    fn {_key, value}, acc ->
      if length(acc) < 100 and matches?(value) do
        [value | acc]
      else
        acc
      end
    end,
    [],
    :my_cache
  )
```

## Ownership Pattern — Critical

**ETS tables belong to the process that creates them.** When the owner crashes, the table is deleted.

For a long-lived shared cache, create the table in a dedicated GenServer (`CacheOwner`) that is supervised:

```elixir
defmodule MyApp.CacheOwner do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def init(_) do
    # Tables live as long as this process lives
    :ets.new(:my_cache, [:set, :public, :named_table,
      read_concurrency: true, write_concurrency: true])
    :ets.new(:my_bag, [:bag, :public, :named_table,
      read_concurrency: true])
    {:ok, nil}
  end
end
```

Add `CacheOwner` before any processes that read/write the tables in your supervision tree.

## Read Concurrency vs Write Concurrency

- `read_concurrency: true` — optimizes for many concurrent reads (lock-free on most architectures)
- `write_concurrency: true` — reduces contention when many processes write simultaneously
- Use both for general-purpose caches
- Don't use `write_concurrency` for `:ordered_set` (higher overhead)

## Serializing Writes via GenServer

For tables that need coordinated updates (e.g. vocabulary tracking), route writes through a GenServer but reads directly against ETS:

```elixir
defmodule MyApp.VocabTracker do
  use GenServer

  # Writes go through GenServer (serialized)
  def update_word(word, count) do
    GenServer.call(__MODULE__, {:update, word, count})
  end

  # Reads go directly to ETS (concurrent, no bottleneck)
  def get_idf(word) do
    case :ets.lookup(:vocab_idf, word) do
      [{^word, idf}] -> idf
      []             -> 0.0
    end
  end

  def handle_call({:update, word, count}, _from, state) do
    :ets.insert(:vocab_idf, {word, compute_idf(count, state.doc_count)})
    {:reply, :ok, %{state | doc_count: state.doc_count + 1}}
  end
end
```

## Common Mistakes

- Don't create ETS tables in a process that might crash — use CacheOwner pattern
- `:named_table` means the atom is the table identifier, not a ref — only one process can own it
- `read_concurrency` and `write_concurrency` trade memory for reduced contention — profile before enabling on many small tables
- ETS is not persisted — survives process crashes but not node restarts
