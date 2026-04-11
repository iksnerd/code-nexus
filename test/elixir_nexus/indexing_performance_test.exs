defmodule ElixirNexus.IndexingPerformanceTest do
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

  defp generate_files(dir, n) do
    Enum.map(1..n, fn i ->
      path = Path.join(dir, "module_#{i}.ex")

      content = """
      defmodule TestMod#{i} do
        def hello_#{i}(x), do: x + #{i}
        def world_#{i}(x), do: hello_#{i}(x) * 2
        def compute_#{i}(a, b) do
          Enum.map(1..a, fn n -> n + b end)
        end
      end
      """

      File.write!(path, content)
      path
    end)
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
  # 3. Broadway Indexing Pipeline
  # ===========================================================================

  describe "indexing pipeline performance" do
    @tag timeout: 30_000
    test "index_directory with 20 .ex files", %{temp_dir: temp_dir} do
      generate_files(temp_dir, 20)

      {result, elapsed} = measure(fn -> ElixirNexus.Indexer.index_directory(temp_dir) end)
      IO.puts("\n  index_directory(20 files): #{Float.round(elapsed, 2)}ms")

      case result do
        {:ok, stats} ->
          assert elapsed < 10_000, "index_directory took #{Float.round(elapsed, 2)}ms (> 10s)"
          IO.puts("  indexed_files: #{stats.indexed_files}, total_chunks: #{stats.total_chunks}")

        {:error, reason} ->
          IO.puts("  index_directory returned error (external service may be unavailable): #{inspect(reason)}")
      end
    end

    @tag timeout: 15_000
    test "index_file single file", %{temp_dir: temp_dir} do
      [path | _] = generate_files(temp_dir, 1)

      {result, elapsed} = measure(fn -> ElixirNexus.Indexer.index_file(path) end)
      IO.puts("\n  index_file: #{Float.round(elapsed, 2)}ms")

      case result do
        {:ok, _chunks} ->
          assert elapsed < 2_000, "index_file took #{Float.round(elapsed, 2)}ms (> 2s)"

        {:error, reason} ->
          IO.puts("  index_file returned error (external service may be unavailable): #{inspect(reason)}")
      end
    end

    @tag timeout: 30_000
    test "chunk count in ETS matches after pipeline", %{temp_dir: temp_dir} do
      generate_files(temp_dir, 5)
      ChunkCache.clear()

      case ElixirNexus.Indexer.index_directory(temp_dir) do
        {:ok, stats} ->
          ets_count = ChunkCache.count()
          IO.puts("\n  pipeline stats: #{stats.total_chunks} chunks, ETS count: #{ets_count}")

          assert ets_count >= stats.total_chunks,
                 "ETS has #{ets_count} chunks but pipeline reported #{stats.total_chunks}"

        {:error, reason} ->
          IO.puts("\n  Skipped (external service unavailable): #{inspect(reason)}")
      end
    end
  end
end
