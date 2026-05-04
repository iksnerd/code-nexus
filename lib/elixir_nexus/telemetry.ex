defmodule ElixirNexus.Telemetry do
  import Telemetry.Metrics

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start:
        {TelemetryMetricsPrometheus.Core, :start_link,
         [[metrics: metrics(), name: __MODULE__]]}
    }
  end

  def metrics do
    [
      # ── Search ────────────────────────────────────────────────────────────
      summary("nexus.search.query.duration_ms",
        unit: :millisecond,
        description: "Hybrid search query latency"
      ),
      counter("nexus.search.query.count",
        event_name: [:nexus, :search, :query],
        measurement: :duration_ms,
        description: "Total search queries"
      ),
      last_value("nexus.search.query.result_count",
        description: "Results returned by last search query"
      ),

      # ── Indexing pipeline ─────────────────────────────────────────────────
      summary("nexus.pipeline.file_parsed.duration_ms",
        unit: :millisecond,
        description: "File parse + chunk latency"
      ),
      counter("nexus.pipeline.file_parsed.count",
        event_name: [:nexus, :pipeline, :file_parsed],
        measurement: :duration_ms,
        description: "Total files successfully parsed"
      ),
      sum("nexus.pipeline.file_parsed.chunk_count",
        description: "Total chunks extracted"
      ),
      counter("nexus.pipeline.file_error.count",
        event_name: [:nexus, :pipeline, :file_error],
        measurement: :duration_ms,
        description: "Total file parse failures"
      ),

      # ── Embedding + storage ───────────────────────────────────────────────
      summary("nexus.embed_and_store.duration_ms",
        unit: :millisecond,
        description: "Embed batch + Qdrant upsert latency"
      ),
      sum("nexus.embed_and_store.chunk_count",
        description: "Total chunks embedded and stored"
      ),

      # ── Qdrant ────────────────────────────────────────────────────────────
      summary("nexus.qdrant.hybrid_search.duration_ms",
        unit: :millisecond,
        description: "Qdrant hybrid search latency"
      ),
      counter("nexus.qdrant.hybrid_search.count",
        event_name: [:nexus, :qdrant, :hybrid_search],
        measurement: :duration_ms,
        description: "Total Qdrant hybrid search calls"
      ),
      summary("nexus.qdrant.upsert.duration_ms",
        unit: :millisecond,
        description: "Qdrant batch upsert latency"
      ),
      sum("nexus.qdrant.upsert.point_count",
        description: "Total points upserted to Qdrant"
      ),
      counter("nexus.qdrant.upsert_error.count",
        event_name: [:nexus, :qdrant, :upsert_error],
        measurement: :batch_size,
        description: "Total failed Qdrant upsert batches"
      ),

      # ── BEAM VM ───────────────────────────────────────────────────────────
      last_value("vm.memory.total", unit: :byte),
      last_value("vm.memory.processes", unit: :byte),
      last_value("vm.memory.binary", unit: :byte),
      last_value("vm.memory.ets", unit: :byte),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.system_counts.process_count")
    ]
  end
end
