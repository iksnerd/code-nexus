# Benchmark: cost of one dashboard LiveView tick — OLD (full assign_stats) vs
# NEW (idle refresh_indicators). Measures the per-tick work that ran every 3s
# for every open browser tab. Run against a hydrated ETS cache.
#
#   MCP_HTTP_PORT=13099 mix run bench/dashboard_tick.exs nexus_control_stack
#
# (MCP_HTTP_PORT just suppresses the dev auto-index so it doesn't clobber ETS.)

alias ElixirNexus.{GraphCache, ChunkCache, ProjectConfig, ProjectSwitcher}

collection = System.argv() |> List.first() || "nexus_control_stack"

IO.puts("Hydrating ETS from Qdrant collection: #{collection} ...")
ProjectSwitcher.switch_project(collection)
ProjectSwitcher.reload_from_qdrant()
Process.sleep(500)

IO.puts("  graph nodes: #{map_size(GraphCache.all_nodes())}, chunks: #{ChunkCache.count()}\n")

# --- the OLD heavy tick: a faithful copy of the pre-fix assign_stats body ---
heavy = fn ->
  graph_nodes = GraphCache.all_nodes()

  _entity_breakdown =
    graph_nodes
    |> Map.values()
    |> Enum.group_by(fn n -> n["entity_type"] || n["type"] || "unknown" end)
    |> Enum.map(fn {t, ns} -> {t, length(ns)} end)
    |> Enum.sort_by(fn {_, c} -> -c end)

  # OLD: ChunkCache.all() materialized TWICE per tick (full payloads)
  _lang =
    ChunkCache.all()
    |> Enum.group_by(fn c -> to_string(c[:language] || c.language || "unknown") end)
    |> Enum.map(fn {l, cs} -> {l, length(cs)} end)

  {root, cfg} = ProjectConfig.current()

  _layers =
    graph_nodes
    |> Map.values()
    |> Enum.reduce(%{}, fn n, acc ->
      path = n["file_path"] || ""
      rel = if root, do: Path.relative_to(path, root), else: path
      Map.update(acc, ProjectConfig.layer_for(cfg, rel), 1, &(&1 + 1))
    end)

  _rels =
    Enum.reduce(Map.values(graph_nodes), {0, 0, 0}, fn n, {a, b, c} ->
      {a + length(n["calls"] || []), b + length(n["is_a"] || []), c + length(n["contains"] || [])}
    end)

  _top =
    graph_nodes
    |> Map.values()
    |> Enum.reject(fn n -> String.length(n["name"] || "") <= 2 end)
    |> Enum.map(fn n -> {n["name"], (n["outgoing_degree"] || 0) + (n["incoming_count"] || 0)} end)
    |> Enum.sort_by(fn {_, d} -> -d end)
    |> Enum.take(5)

  _files = ChunkCache.all() |> Enum.map(& &1.file_path) |> Enum.uniq() |> length()
  :ok
end

# --- the NEW idle tick: refresh_indicators (cheap status reads only) ---
light = fn ->
  _ = ElixirNexus.Indexer.status()
  _ = ElixirNexus.EmbeddingModel.available?()
  _ = ElixirNexus.FileWatcher.status()
  _ = ElixirNexus.QdrantClient.health_check()
  :ok
end

measure = fn label, fun, n ->
  fun.()                                   # warm up
  :erlang.garbage_collect()
  {gcs0, words0, _} = :erlang.statistics(:garbage_collection)
  {r0, _} = :erlang.statistics(:reductions)
  {us, _} = :timer.tc(fn -> for _ <- 1..n, do: fun.() end)
  {r1, _} = :erlang.statistics(:reductions)
  {gcs1, words1, _} = :erlang.statistics(:garbage_collection)

  IO.puts(label)
  IO.puts("  wall:       #{Float.round(us / n / 1000, 3)} ms / tick")
  IO.puts("  reductions: #{div(r1 - r0, n)} / tick")
  IO.puts("  garbage:    #{div(words1 - words0, n)} words reclaimed / tick (GC pressure)")
  IO.puts("  GC runs:    #{Float.round((gcs1 - gcs0) / n, 2)} / tick\n")
  {us / n / 1000, div(r1 - r0, n), div(words1 - words0, n)}
end

n = 200
IO.puts("Averaging over #{n} iterations each:\n")
{hw, hr, hg} = measure.("OLD  full assign_stats (ran every 3s, every tab):", heavy, n)
{lw, lr, lg} = measure.("NEW  idle refresh_indicators:", light, n)

ticks_per_min = 20
IO.puts("--- per open dashboard tab ---")
IO.puts("wall time saved:  #{Float.round((hw - lw) * ticks_per_min, 1)} ms/min  (#{Float.round(hw / max(lw, 0.001), 1)}x cheaper/tick)")
IO.puts("reductions saved: #{(hr - lr) * ticks_per_min} /min")
IO.puts("garbage avoided:  #{Float.round((hg - lg) * ticks_per_min * 8 / 1_000_000, 1)} MB/min reclaimed")
