---
name: elixir-otp-registry
description: Elixir Registry for dynamic process discovery and local pub/sub. Use when registering named processes dynamically, looking up processes by key, dispatching messages to multiple registered processes, or implementing local pub/sub without external infrastructure.
metadata:
  source: hexdocs.pm/elixir/Registry
  docs: https://hexdocs.pm/elixir/Registry.html
---

# Elixir Registry

## Setup

Add to supervision tree:

```elixir
# application.ex — start before processes that register
children = [
  {Registry, keys: :unique, name: MyApp.Registry},
  # ... processes that register themselves
]
```

## :unique vs :duplicate

| Mode | Use for |
|---|---|
| `:unique` | One process per key — service discovery, named singletons |
| `:duplicate` | Multiple processes per key — pub/sub topics, fan-out dispatch |

## Process Registration

### Via tuple (register on start_link)

```elixir
defmodule MyApp.Worker do
  def start_link(id) do
    GenServer.start_link(__MODULE__, id,
      name: {:via, Registry, {MyApp.Registry, id}})
  end
end

# Start multiple workers with unique keys
{:ok, _} = MyApp.Worker.start_link("worker-1")
{:ok, _} = MyApp.Worker.start_link("worker-2")
```

### Manual registration (in init/1 or anywhere)

```elixir
def init(key) do
  Registry.register(MyApp.Registry, key, %{meta: "data"})
  {:ok, %{key: key}}
end
```

## Process Lookup

```elixir
# Unique registry — returns [{pid, value}] or []
case Registry.lookup(MyApp.Registry, "worker-1") do
  [{pid, _meta}] -> GenServer.call(pid, :work)
  []             -> {:error, :not_found}
end
```

## Dispatch (fan-out to all registered)

```elixir
# Dispatch to all processes registered under a topic key
Registry.dispatch(MyApp.Registry, "events:user", fn entries ->
  for {pid, _meta} <- entries do
    send(pid, {:event, :user_created})
  end
end)
```

## Local Pub/Sub with :duplicate

```elixir
# Subscriber registers interest
Registry.register(MyApp.Registry, "topic:orders", nil)

# Publisher dispatches to all subscribers
Registry.dispatch(MyApp.Registry, "topic:orders", fn entries ->
  for {pid, _} <- entries, do: send(pid, {:order, order})
end)
```

## Automatic Cleanup

Registry automatically removes entries when a process exits. No manual cleanup needed — crashed processes disappear from the registry.

## With Metadata

```elixir
# Register with metadata
Registry.register(MyApp.Registry, key, %{started_at: DateTime.utc_now()})

# Update metadata
Registry.update_value(MyApp.Registry, key, fn meta ->
  Map.put(meta, :last_seen, DateTime.utc_now())
end)
```

## Partitioning for High Concurrency

```elixir
{Registry, keys: :unique, name: MyApp.Registry, partitions: System.schedulers_online()}
```

Partitioning reduces lock contention when many processes register/unregister concurrently. Default is 1 partition.

## Common Patterns

### GenServer that registers itself
```elixir
def start_link(session_id) do
  GenServer.start_link(__MODULE__, session_id,
    name: {:via, Registry, {MyApp.Registry, {:session, session_id}}})
end

# Any process can find and message it
def send_to_session(session_id, msg) do
  case Registry.lookup(MyApp.Registry, {:session, session_id}) do
    [{pid, _}] -> GenServer.cast(pid, msg)
    []         -> {:error, :session_not_found}
  end
end
```

### IndexingProducer self-lookup pattern (from ElixirNexus)
```elixir
def init(state) do
  Registry.register(MyApp.Registry, :indexing_producer, nil)
  {:producer, state}
end

def push_item(item) do
  case Registry.lookup(MyApp.Registry, :indexing_producer) do
    [{pid, _}] -> send(pid, {:push, item})
    []         -> {:error, :producer_not_started}
  end
end
```
