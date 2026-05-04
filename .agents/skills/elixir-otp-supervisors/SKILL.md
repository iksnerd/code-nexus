---
name: elixir-otp-supervisors
description: OTP Supervisor strategies and supervision tree design. Use when setting up a supervision tree, choosing a restart strategy (one_for_one, one_for_all, rest_for_one), configuring child specs, handling restart intensity, or designing fault-tolerant process hierarchies.
metadata:
  source: hexdocs.pm/elixir/Supervisor
  docs: https://hexdocs.pm/elixir/Supervisor.html
---

# OTP Supervisors

## Three Restart Strategies

| Strategy | Behavior | Use when |
|---|---|---|
| `:one_for_one` | Only crashed child restarts | Children are independent |
| `:one_for_all` | All children restart | Children are tightly coupled |
| `:rest_for_one` | Crashed child + all children after it restart | Later children depend on earlier ones |

## one_for_one (Most Common)

```elixir
children = [
  MyApp.UserCache,
  MyApp.SessionCache,
  MyApp.Worker,
]

Supervisor.start_link(children, strategy: :one_for_one)
```

Use this when children are independent — a crash in one doesn't affect others.

## rest_for_one (Dependency Ordering)

```elixir
# Order matters: later children depend on earlier ones
children = [
  {Registry, keys: :unique, name: MyApp.Registry},  # must start first
  MyApp.CacheOwner,          # depends on nothing
  MyApp.QdrantClient,        # depends on nothing
  MyApp.Indexer,             # depends on CacheOwner
  MyApp.IndexingPipeline,    # depends on Indexer
  MyApp.FileWatcher,         # depends on IndexingPipeline
]

Supervisor.start_link(children, strategy: :rest_for_one)
```

When `CacheOwner` crashes, `Indexer`, `IndexingPipeline`, and `FileWatcher` all restart too (they depend on it). Registry and QdrantClient are unaffected.

## one_for_all

```elixir
children = [
  MyApp.DatabasePool,
  MyApp.CacheLayer,   # meaningless without DB
]

Supervisor.start_link(children, strategy: :one_for_all)
```

Use when all children must be in sync — rarely needed.

## Child Spec

Every child needs a child spec. GenServer and Supervisor provide defaults:

```elixir
# Long form (explicit)
children = [
  %{
    id: MyApp.Worker,
    start: {MyApp.Worker, :start_link, [[name: :worker]]},
    restart: :permanent,   # :permanent | :temporary | :transient
    shutdown: 5000,        # ms to wait before brutal kill
    type: :worker          # :worker | :supervisor
  }
]

# Short form (uses child_spec/1)
children = [
  {MyApp.Worker, [name: :worker]},
  MyApp.SimpleWorker,         # no args
]
```

## Restart Intensity (Preventing Loops)

```elixir
Supervisor.start_link(children,
  strategy: :one_for_one,
  max_restarts: 3,    # max crashes in...
  max_seconds: 5      # ...this window before supervisor itself exits
)
```

Default: 3 restarts in 5 seconds. Tune for your workload — high-throughput pipelines may need higher limits.

## Application Supervisor

The top-level supervisor lives in `application.ex`:

```elixir
defmodule MyApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MyApp.Repo,
      {Phoenix.PubSub, name: MyApp.PubSub},
      MyAppWeb.Endpoint,
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

## Task.Supervisor for Dynamic Tasks

```elixir
# Add to children list
{Task.Supervisor, name: MyApp.TaskSupervisor}

# Fire-and-forget supervised task
Task.Supervisor.start_child(MyApp.TaskSupervisor, fn ->
  do_background_work()
end)

# Awaitable supervised task
task = Task.Supervisor.async(MyApp.TaskSupervisor, fn ->
  compute_something()
end)
result = Task.await(task, 30_000)
```

## Design Principles

- Group children by domain in nested supervisors for large apps
- Avoid deeply nested supervision trees — keep flat where possible
- Children should handle crashing and restarting cleanly (idempotent `init/1`)
- Use `:temporary` restart for tasks that should not be restarted on failure
- Use `:transient` restart for processes that exit normally on purpose
