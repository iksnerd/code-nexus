---
name: elixir-broadway-pipeline
description: Broadway data pipeline patterns for concurrent, fault-tolerant message processing. Use when building a processing pipeline with producers, processors, and batchers, configuring back-pressure and concurrency, handling errors and retries, or partitioning messages for ordered processing.
metadata:
  source: hexdocs.pm/broadway + ElixirNexus indexing pipeline
  docs: https://hexdocs.pm/broadway/Broadway.html
---

# Broadway Data Pipelines

## Architecture

```
Producer(s) → Processor(s) → [Batcher(s)] → BatchProcessor(s)
```

- **Producer**: pulls or receives messages (GenStage producer)
- **Processor**: handles individual messages, routes to batchers
- **Batcher**: groups messages by size/time, sends batches downstream
- **BatchProcessor**: handles batches (bulk DB writes, external API calls)

## Basic Pipeline

```elixir
defmodule MyApp.Pipeline do
  use Broadway

  def start_link(_opts) do
    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {MyApp.Producer, []},
        concurrency: 1
      ],
      processors: [
        default: [
          concurrency: System.schedulers_online(),
          max_demand: 10
        ]
      ],
      batchers: [
        store: [
          batch_size: 50,
          batch_timeout: 2000,
          concurrency: 2
        ]
      ]
    )
  end

  @impl true
  def handle_message(_processor, message, _context) do
    case process(message.data) do
      {:ok, result} ->
        message
        |> Broadway.Message.update_data(fn _ -> result end)
        |> Broadway.Message.put_batcher(:store)

      {:error, reason} ->
        Broadway.Message.failed(message, reason)
    end
  end

  @impl true
  def handle_batch(:store, messages, _batch_info, _context) do
    items = Enum.map(messages, & &1.data)
    MyApp.Store.bulk_insert(items)
    messages
  end

  @impl true
  def handle_failed(messages, _context) do
    Enum.each(messages, fn msg ->
      Logger.error("Failed: #{inspect(msg.status)}")
    end)
    messages
  end
end
```

## Custom Producer (GenStage)

For pushing work into Broadway from the application:

```elixir
defmodule MyApp.Producer do
  use GenStage

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def push(items) when is_list(items) do
    send(__MODULE__, {:push, items})
  end

  @impl true
  def init(_opts) do
    {:producer, %{queue: :queue.new(), demand: 0}}
  end

  @impl true
  def handle_demand(demand, state) do
    dispatch(%{state | demand: state.demand + demand})
  end

  @impl true
  def handle_info({:push, items}, state) do
    queue = Enum.reduce(items, state.queue, &:queue.in/2)
    dispatch(%{state | queue: queue})
  end

  defp dispatch(%{queue: queue, demand: demand} = state) when demand > 0 do
    {items, remaining_demand, new_queue} = take_from_queue(queue, demand, [])
    events = Enum.map(items, &%Broadway.Message{data: &1, acknowledger: {__MODULE__, :ack, nil}})
    {:noreply, events, %{state | queue: new_queue, demand: remaining_demand}}
  end
  defp dispatch(state), do: {:noreply, [], state}
end
```

## Concurrency Tuning

```elixir
processors: [
  default: [
    # Match number of CPU schedulers for CPU-bound work
    # For I/O-bound work: multiply by 2-4
    concurrency: System.schedulers_online(),
    max_demand: 5    # Per-processor batch size pulled from producer
  ]
],
batchers: [
  embed_and_store: [
    batch_size: 32,          # Accumulate 32 messages per batch
    batch_timeout: 1000,     # Or flush after 1s, whichever comes first
    concurrency: div(System.schedulers_online(), 2)
  ]
]
```

## Partitioning (Ordered Processing)

Guarantee message order within a partition while maintaining concurrency across partitions:

```elixir
# In handle_message — route by partition key
def handle_message(_processor, message, _context) do
  message
  |> Broadway.Message.put_batcher(:default)
  |> Broadway.Message.put_batch_key(message.data.user_id)  # order by user
end
```

## Error Handling

```elixir
def handle_message(_processor, message, _context) do
  case risky_operation(message.data) do
    {:ok, result} ->
      Broadway.Message.update_data(message, fn _ -> result end)

    {:error, :retryable} ->
      # Mark failed — message goes to handle_failed
      Broadway.Message.failed(message, :retryable)

    {:error, :fatal} ->
      Broadway.Message.failed(message, :fatal)
  end
end

def handle_failed(messages, _context) do
  {retryable, fatal} = Enum.split_with(messages, & &1.status == {:failed, :retryable})

  # Requeue retryable messages
  Enum.each(retryable, fn msg ->
    MyApp.Producer.push([msg.data])
  end)

  # Log fatal errors
  Enum.each(fatal, fn msg ->
    Logger.error("Fatal failure: #{inspect(msg.data)}")
  end)

  messages  # Must return messages
end
```

## ElixirNexus Pipeline Structure

```
IndexingProducer (GenStage, 1 instance)
  → Processor (concurrency: schedulers, max_demand: 5)
    → parse file → emit telemetry → put_batcher(:embed_and_store)
  → Batcher :embed_and_store (batch_size: 32, timeout: 1000ms)
    → embed chunks with Ollama → store to Qdrant + ETS → broadcast progress
```

Key patterns used:
- `Registry.lookup` to find producer PID for pushing work
- Telemetry events emitted from `handle_message` for per-file tracking
- Batch size 32 matches Ollama embedding batch efficiency
