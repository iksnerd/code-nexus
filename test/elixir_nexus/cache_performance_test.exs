defmodule ElixirNexus.CachePerformanceTest do
  use ExUnit.Case, async: false

  @moduletag :performance

  alias ElixirNexus.ChunkCache
  alias ElixirNexus.GraphCache

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp measure(fun) do
    {elapsed_us, result} = :timer.tc(fun)
    {result, elapsed_us / 1_000}
  end

  defp assert_under(ms, fun) do
    {result, elapsed_ms} = measure(fun)

    assert elapsed_ms < ms,
           "Expected < #{ms}ms, got #{Float.round(elapsed_ms, 2)}ms"

    {result, elapsed_ms}
  end

  defp generate_chunks(n) do
    Enum.map(1..n, fn i ->
      %{
        id: "chunk_#{i}",
        file_path: "lib/mod_#{i}.ex",
        name: "function_#{i}",
        content: "def function_#{i}(a, b), do: a + b + #{i}",
        entity_type: :function,
        visibility: :public,
        parameters: ["a", "b"],
        calls: ["function_#{rem(i, n) + 1}", "Enum.map"],
        is_a: [],
        contains: [],
        module_path: "Mod#{i}",
        start_line: 1,
        end_line: 3,
        language: :elixir
      }
    end)
  end

  defp percentile(sorted_list, p) do
    k = max(0, round(length(sorted_list) * p / 100) - 1)
    Enum.at(sorted_list, k)
  end

  defp ensure_ets_table(name) do
    case :ets.info(name) do
      :undefined -> :ets.new(name, [:set, :public, :named_table, read_concurrency: true])
      _ -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    ensure_ets_table(:nexus_chunk_cache)
    ensure_ets_table(:nexus_graph_cache)

    on_exit(fn ->
      try do
        ChunkCache.clear()
      rescue
        _ -> :ok
      end

      try do
        GraphCache.clear()
      rescue
        _ -> :ok
      end
    end)

    temp_dir = Path.join(System.tmp_dir!(), "perf_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, temp_dir: temp_dir}
  end

  # ===========================================================================
  # 1. ETS ChunkCache Performance
  # ===========================================================================

  describe "ChunkCache performance" do
    test "insert_many with 1K chunks" do
      chunks = generate_chunks(1_000)
      {_result, elapsed} = assert_under(100, fn -> ChunkCache.insert_many(chunks) end)
      IO.puts("\n  insert_many(1K): #{Float.round(elapsed, 2)}ms")
    end

    test "insert_many with 5K chunks" do
      chunks = generate_chunks(5_000)
      {_result, elapsed} = assert_under(100, fn -> ChunkCache.insert_many(chunks) end)
      IO.puts("\n  insert_many(5K): #{Float.round(elapsed, 2)}ms")
    end

    test "insert_many with 10K chunks" do
      chunks = generate_chunks(10_000)
      {_result, elapsed} = assert_under(100, fn -> ChunkCache.insert_many(chunks) end)
      IO.puts("\n  insert_many(10K): #{Float.round(elapsed, 2)}ms")
    end

    test "search with 10K chunks" do
      chunks = generate_chunks(10_000)
      ChunkCache.insert_many(chunks)

      {_result, elapsed} = assert_under(50, fn -> ChunkCache.search("function_500") end)
      IO.puts("\n  search(10K): #{Float.round(elapsed, 2)}ms")
    end

    test "count with 10K chunks" do
      chunks = generate_chunks(10_000)
      ChunkCache.insert_many(chunks)

      {count, elapsed} = assert_under(1, fn -> ChunkCache.count() end)
      IO.puts("\n  count(10K): #{Float.round(elapsed, 2)}ms")
      assert count == 10_000
    end

    test "delete_by_file" do
      chunks = generate_chunks(10_000)
      ChunkCache.insert_many(chunks)

      {_result, elapsed} = assert_under(10, fn -> ChunkCache.delete_by_file("lib/mod_42.ex") end)
      IO.puts("\n  delete_by_file: #{Float.round(elapsed, 2)}ms")
    end

    test "all with 10K chunks" do
      chunks = generate_chunks(10_000)
      ChunkCache.insert_many(chunks)

      {result, elapsed} = measure(fn -> ChunkCache.all() end)
      IO.puts("\n  all(10K): #{Float.round(elapsed, 2)}ms, #{length(result)} items")
      assert length(result) == 10_000
    end

    test "concurrent reads: 100 parallel search calls with 10K chunks" do
      chunks = generate_chunks(10_000)
      ChunkCache.insert_many(chunks)

      tasks =
        Enum.map(1..100, fn i ->
          Task.async(fn ->
            {_result, elapsed} = measure(fn -> ChunkCache.search("function_#{i}") end)
            elapsed
          end)
        end)

      latencies =
        tasks
        |> Enum.map(&Task.await(&1, 10_000))
        |> Enum.sort()

      p99 = percentile(latencies, 99)
      IO.puts("\n  concurrent search p50: #{Float.round(percentile(latencies, 50), 2)}ms")
      IO.puts("  concurrent search p99: #{Float.round(p99, 2)}ms")
      assert p99 < 2_000, "p99 latency #{Float.round(p99, 2)}ms exceeds 2000ms"
    end
  end

  # ===========================================================================
  # 2. ETS GraphCache Performance
  # ===========================================================================

  describe "GraphCache performance" do
    test "rebuild_from_chunks with 1K chunks" do
      chunks = generate_chunks(1_000)

      {_result, elapsed} = assert_under(10_000, fn -> GraphCache.rebuild_from_chunks(chunks) end)
      IO.puts("\n  rebuild_from_chunks(1K): #{Float.round(elapsed, 2)}ms")
    end

    test "all_nodes with 1K nodes" do
      chunks = generate_chunks(1_000)
      GraphCache.rebuild_from_chunks(chunks)

      {nodes, elapsed} = assert_under(10, fn -> GraphCache.all_nodes() end)
      IO.puts("\n  all_nodes(#{map_size(nodes)}): #{Float.round(elapsed, 2)}ms")
    end

    test "find_callers with 1K nodes" do
      chunks = generate_chunks(1_000)
      GraphCache.rebuild_from_chunks(chunks)

      {_result, elapsed} = assert_under(20, fn -> GraphCache.find_callers("function_42") end)
      IO.puts("\n  find_callers(1K): #{Float.round(elapsed, 2)}ms")
    end

    test "put_node / get_node sub-millisecond" do
      node = %{"id" => "test_node", "name" => "foo", "calls" => [], "is_a" => [], "contains" => []}

      {_r1, put_elapsed} = assert_under(1, fn -> GraphCache.put_node("test_node", node) end)
      {_r2, get_elapsed} = assert_under(1, fn -> GraphCache.get_node("test_node") end)
      IO.puts("\n  put_node: #{Float.round(put_elapsed, 3)}ms, get_node: #{Float.round(get_elapsed, 3)}ms")
    end
  end
end
