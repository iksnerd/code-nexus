defmodule ElixirNexus.GraphPerformanceTest do
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
  # 6. Graph Query Performance (Queries module via ETS)
  # ===========================================================================

  describe "graph query performance" do
    setup do
      # Populate ETS with realistic data so queries use the fast path
      chunks = generate_chunks(500)
      ChunkCache.insert_many(chunks)
      GraphCache.rebuild_from_chunks(chunks)
      :ok
    end

    test "analyze_impact with cached ETS data" do
      {result, elapsed} =
        assert_under(200, fn ->
          ElixirNexus.Search.analyze_impact("function_1")
        end)

      case result do
        {:ok, impact} ->
          IO.puts("\n  analyze_impact: #{Float.round(elapsed, 2)}ms, affected: #{impact.total_affected}")

        {:error, reason} ->
          IO.puts("\n  analyze_impact: #{Float.round(elapsed, 2)}ms, error: #{inspect(reason)}")
      end
    end

    test "find_callees with cached ETS data" do
      {result, elapsed} =
        assert_under(100, fn ->
          ElixirNexus.Search.find_callees("function_1")
        end)

      case result do
        {:ok, callees} ->
          IO.puts("\n  find_callees: #{Float.round(elapsed, 2)}ms, found: #{length(callees)}")

        {:error, reason} ->
          IO.puts("\n  find_callees: #{Float.round(elapsed, 2)}ms, error: #{inspect(reason)}")
      end
    end

    test "get_community_context with cached ETS data" do
      {result, elapsed} =
        assert_under(200, fn ->
          ElixirNexus.Search.get_community_context("lib/mod_1.ex")
        end)

      case result do
        {:ok, ctx} ->
          IO.puts(
            "\n  get_community_context: #{Float.round(elapsed, 2)}ms, coupled_files: #{length(ctx.coupled_files)}"
          )

        {:error, reason} ->
          IO.puts("\n  get_community_context: #{Float.round(elapsed, 2)}ms, error: #{inspect(reason)}")
      end
    end
  end
end
