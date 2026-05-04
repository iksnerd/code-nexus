---
name: elixir-task-concurrency
description: Task and Task.Supervisor patterns for concurrent work in Elixir. Use when running work concurrently, processing collections in parallel with Task.async_stream, firing background jobs without awaiting, or handling task timeouts and failures.
metadata:
  source: hexdocs.pm/elixir/Task
  docs: https://hexdocs.pm/elixir/Task.html
---

# Task Concurrency

## async / await — Parallel Work with Result

```elixir
# Spawn concurrent tasks
task_a = Task.async(fn -> fetch_users() end)
task_b = Task.async(fn -> fetch_products() end)

# Collect results (blocks until both complete)
users    = Task.await(task_a, 10_000)   # 10s timeout
products = Task.await(task_b, 10_000)
```

- `Task.async` links the task to the caller — if the caller crashes, the task is killed
- `Task.await/2` can only be called by the process that spawned the task
- Default timeout is 5000ms — always set explicitly for I/O-bound work

## Task.async_stream — Parallel Enumeration

Best for processing a collection concurrently with back-pressure:

```elixir
files
|> Task.async_stream(&process_file/1,
     max_concurrency: System.schedulers_online(),
     timeout: 30_000,
     on_timeout: :kill_task)
|> Enum.reduce({[], []}, fn
  {:ok, result}, {ok, err}    -> {[result | ok], err}
  {:exit, reason}, {ok, err}  -> {ok, [{:failed, reason} | err]}
end)
```

Options:
- `max_concurrency` — default `System.schedulers_online()`, cap to avoid overwhelming external services
- `timeout` — per-task timeout in ms
- `on_timeout: :kill_task` — kill timed-out tasks (default: raise)
- `ordered: false` — don't preserve order, slightly faster

## Fire-and-Forget with Task.Supervisor

For background work where you don't need the result and don't want to crash the caller on failure:

```elixir
# Add to supervision tree in application.ex
{Task.Supervisor, name: MyApp.TaskSupervisor}

# Fire-and-forget
Task.Supervisor.start_child(MyApp.TaskSupervisor, fn ->
  send_welcome_email(user)
end)
```

## Task.Supervisor.async — Supervised with Result

Better fault tolerance than bare `Task.async`:

```elixir
task = Task.Supervisor.async(MyApp.TaskSupervisor, fn ->
  compute_expensive_report()
end)

case Task.yield(task, 60_000) || Task.shutdown(task) do
  {:ok, result} -> result
  nil           -> {:error, :timeout}
end
```

`Task.yield/2` returns `nil` on timeout (doesn't raise), letting you clean up gracefully.

## Boot-time Tasks

Run startup work after the application is ready:

```elixir
# application.ex — after supervision tree starts
def start(_type, _args) do
  children = [...]
  {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)

  Task.Supervisor.start_child(MyApp.TaskSupervisor, fn ->
    # Wait for dependent services to be ready
    Process.sleep(1000)
    MyApp.Indexer.index_default_project()
  end)

  {:ok, sup}
end
```

## Task vs GenServer vs Process

| Need | Use |
|---|---|
| Short parallel work, need result | `Task.async` + `Task.await` |
| Process a collection in parallel | `Task.async_stream` |
| Background job, no result needed | `Task.Supervisor.start_child` |
| Long-lived stateful process | `GenServer` |
| Stateless isolated work | `Task` |

## Common Mistakes

- Don't `Task.await` from a different process than the one that called `Task.async` (will crash)
- Don't ignore task failures — use `Task.yield/2` not just `Task.await/2` when timeout is possible
- Set `max_concurrency` when calling external services — default can overwhelm rate limits
- `Task.async` links tasks to caller — a crash in any task crashes the caller too. Use `Task.Supervisor` for isolation.
