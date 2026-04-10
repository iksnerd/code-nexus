---
name: elixir-telemetry
description: Telemetry instrumentation and observability patterns for Elixir. Use when adding metrics, tracing, or monitoring to Elixir code, attaching handlers to telemetry events, implementing span events, or integrating with Phoenix/Ecto telemetry.
metadata:
  source: hexdocs.pm/telemetry + ElixirNexus codebase
  docs: https://hexdocs.pm/telemetry/readme.html
---

# Telemetry Instrumentation

## Core Concept

Telemetry is a decoupled instrumentation system. Libraries emit events; applications attach handlers. No tight coupling between producers and consumers.

- **Event name**: list of atoms `[:app, :component, :event]`
- **Measurements**: numeric values map `%{duration: 1200, count: 5}`
- **Metadata**: contextual map `%{file: "foo.ex", query: "SELECT..."}`

## Emitting Events

### Point Event

```elixir
start = System.monotonic_time()
result = do_work(file)
duration = System.monotonic_time() - start

:telemetry.execute(
  [:myapp, :pipeline, :file_parsed],
  %{duration: System.convert_time_unit(duration, :native, :millisecond),
    chunk_count: length(result.chunks)},
  %{file: file, status: :ok}
)
```

### Error Event

```elixir
:telemetry.execute(
  [:myapp, :pipeline, :file_error],
  %{count: 1},
  %{file: file, reason: reason}
)
```

### Span Events (start/stop/exception)

Use `:telemetry.span/3` for automatic start + stop timing:

```elixir
:telemetry.span(
  [:myapp, :qdrant, :upsert],
  %{batch_size: length(points)},
  fn ->
    result = Qdrant.upsert(points)
    {result, %{point_count: length(points)}}
  end
)
```

This emits `[:myapp, :qdrant, :upsert, :start]`, `[:myapp, :qdrant, :upsert, :stop]`, and on exception `[:myapp, :qdrant, :upsert, :exception]` automatically.

## Attaching Handlers

```elixir
# In application.ex or a telemetry module
:telemetry.attach(
  "myapp-pipeline-handler",           # unique handler id
  [:myapp, :pipeline, :file_parsed],  # event name
  &MyApp.TelemetryHandler.handle_event/4,
  nil                                 # config passed to handler
)

# Attach multiple events at once
:telemetry.attach_many(
  "myapp-qdrant-handler",
  [
    [:myapp, :qdrant, :upsert],
    [:myapp, :qdrant, :upsert_error],
    [:myapp, :qdrant, :hybrid_search],
  ],
  &MyApp.TelemetryHandler.handle_event/4,
  nil
)
```

## Handler Implementation

```elixir
defmodule MyApp.TelemetryHandler do
  def handle_event([:myapp, :pipeline, :file_parsed], measurements, metadata, _config) do
    Logger.info("Parsed #{metadata.file} in #{measurements.duration}ms " <>
                "(#{measurements.chunk_count} chunks)")
    # Report to StatsD, Prometheus, etc.
  end

  def handle_event([:myapp, :pipeline, :file_error], _measurements, metadata, _config) do
    Logger.warning("Parse error in #{metadata.file}: #{inspect(metadata.reason)}")
  end
end
```

**Critical**: Handler callbacks execute **synchronously** in the process that emitted the event. Never do blocking I/O in a handler — send to a separate process instead:

```elixir
def handle_event(event, measurements, metadata, _config) do
  # Good — async dispatch
  send(MyApp.MetricsAggregator, {:telemetry, event, measurements, metadata})
end
```

## Timing with monotonic_time

Always use `System.monotonic_time/0` for duration measurements (not `DateTime.utc_now/0`):

```elixir
start = System.monotonic_time()
result = expensive_operation()
duration_ms = System.convert_time_unit(
  System.monotonic_time() - start,
  :native,
  :millisecond
)
```

## ElixirNexus Telemetry Events

| Event | Measurements | Metadata |
|---|---|---|
| `[:nexus, :pipeline, :file_parsed]` | `duration_ms`, `chunk_count` | `file` |
| `[:nexus, :pipeline, :file_error]` | `count` | `file`, `reason` |
| `[:nexus, :search, :query]` | `duration_ms`, `result_count` | `query` |
| `[:nexus, :qdrant, :upsert]` | `duration_ms`, `point_count` | — |
| `[:nexus, :qdrant, :upsert_error]` | `batch_size` | `reason` |
| `[:nexus, :qdrant, :hybrid_search]` | `duration_ms`, `limit` | — |
| `[:nexus, :embed_and_store]` | `duration_ms`, `chunk_count` | — |

## Common Mistakes

- Don't block in telemetry handlers — offload to async process
- Don't use wall-clock time for durations — use `System.monotonic_time/0`
- Handler IDs must be globally unique — use namespaced strings like `"myapp-component-action"`
- Detach handlers on teardown to avoid memory leaks in tests: `:telemetry.detach("handler-id")`
