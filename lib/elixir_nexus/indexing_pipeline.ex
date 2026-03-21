defmodule ElixirNexus.IndexingPipeline do
  @moduledoc """
  Broadway pipeline for bulk indexing: parse -> chunk -> embed -> store.
  Provides back-pressure, auto-batching, and fault tolerance.
  """
  use Broadway
  require Logger

  alias ElixirNexus.{ChunkCache, Events, IndexingHelpers}

  @batch_size 32

  def start_link(opts) do
    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {ElixirNexus.IndexingProducer, opts},
        transformer: {__MODULE__, :transform, []},
        concurrency: 1
      ],
      processors: [
        default: [
          concurrency: System.schedulers_online(),
          max_demand: 5
        ]
      ],
      batchers: [
        embed_and_store: [
          batch_size: @batch_size,
          batch_timeout: 1_000,
          concurrency: System.schedulers_online() |> div(2) |> max(2)
        ]
      ]
    )
  end

  def transform(event, _opts) do
    %Broadway.Message{
      data: event,
      acknowledger: {__MODULE__, :ack_id, :ack_data}
    }
  end

  def ack(:ack_id, _successful, _failed) do
    :ok
  end

  @impl true
  def handle_message(:default, message, _context) do
    file_path = message.data

    start = System.monotonic_time()

    case IndexingHelpers.process_file(file_path) do
      {:ok, chunks} ->
        duration_ms = System.convert_time_unit(System.monotonic_time() - start, :native, :millisecond)
        :telemetry.execute([:nexus, :pipeline, :file_parsed], %{duration_ms: duration_ms, chunk_count: length(chunks)}, %{file: file_path})
        ElixirNexus.DirtyTracker.mark_clean(file_path)

        message
        |> Broadway.Message.put_data({file_path, chunks})
        |> Broadway.Message.put_batcher(:embed_and_store)

      {:error, reason} ->
        :telemetry.execute([:nexus, :pipeline, :file_error], %{}, %{file: file_path, reason: reason})
        Logger.warning("Pipeline: failed to process #{file_path}: #{inspect(reason)}")

        message
        |> Broadway.Message.put_data({file_path, []})
        |> Broadway.Message.put_batcher(:embed_and_store)
    end
  end

  @impl true
  def handle_batch(:embed_and_store, messages, _batch_info, _context) do
    # Flatten all chunks from this batch of files
    file_chunks_pairs = Enum.map(messages, fn msg -> msg.data end)

    all_chunks =
      file_chunks_pairs
      |> Enum.flat_map(fn {_path, chunks} -> chunks end)

    if all_chunks != [] do
      IndexingHelpers.embed_and_store(all_chunks)

      # Insert into ETS cache (graph rebuild happens once at pipeline completion)
      ChunkCache.insert_many(all_chunks)

      # Broadcast progress
      Events.broadcast_indexing_progress(%{
        batch_chunks: length(all_chunks),
        batch_files: length(messages)
      })
    end

    # Send acks directly to the Indexer for completion tracking
    Enum.each(file_chunks_pairs, fn {file_path, chunks} ->
      send(ElixirNexus.Indexer, {:file_indexed, file_path, length(chunks)})
    end)

    messages
  end
end
