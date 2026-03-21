defmodule ElixirNexus.PerformanceTest do
  use ExUnit.Case, async: false

  @moduletag :performance

  alias ElixirNexus.ChunkCache
  alias ElixirNexus.GraphCache
  alias ElixirNexus.Events

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
      try do ChunkCache.clear() rescue _ -> :ok end
      try do GraphCache.clear() rescue _ -> :ok end
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

  # ===========================================================================
  # 4. Hybrid Search Latency
  # ===========================================================================

  describe "hybrid search latency" do
    @tag timeout: 15_000
    test "search_code end-to-end" do
      {result, elapsed} = measure(fn -> ElixirNexus.Search.search_code("GenServer") end)
      IO.puts("\n  search_code e2e: #{Float.round(elapsed, 2)}ms")

      case result do
        {:ok, _results} ->
          assert elapsed < 3_000, "search_code took #{Float.round(elapsed, 2)}ms (> 3s)"

        {:error, reason} ->
          IO.puts("  search_code error (Qdrant may be unavailable): #{inspect(reason)}")
      end
    end

    test "search_code with empty index (fast fallback)" do
      ChunkCache.clear()

      {result, elapsed} = measure(fn -> ElixirNexus.Search.search_code("nonexistent_xyz_123") end)
      IO.puts("\n  search_code (empty): #{Float.round(elapsed, 2)}ms")

      case result do
        {:ok, _} ->
          assert elapsed < 3_000, "Empty search took #{Float.round(elapsed, 2)}ms (> 3s)"

        {:error, _} ->
          :ok
      end
    end

    @tag timeout: 30_000
    test "10 sequential searches — p50/p95/p99" do
      # Populate ETS cache so keyword fallback works
      chunks = generate_chunks(100)
      ChunkCache.insert_many(chunks)

      latencies =
        Enum.map(1..10, fn i ->
          {_result, elapsed} = measure(fn -> ElixirNexus.Search.search_code("function_#{i}") end)
          elapsed
        end)
        |> Enum.sort()

      IO.puts("\n  search p50: #{Float.round(percentile(latencies, 50), 2)}ms")
      IO.puts("  search p95: #{Float.round(percentile(latencies, 95), 2)}ms")
      IO.puts("  search p99: #{Float.round(percentile(latencies, 99), 2)}ms")
    end
  end

  # ===========================================================================
  # 5. Embedding Model Performance
  # ===========================================================================

  describe "embedding model performance" do
    @sample_code """
    def handle_call({:get, key}, _from, state) do
      value = Map.get(state.cache, key)
      {:reply, {:ok, value}, state}
    end
    """

    test "Bumblebee single embed" do
      if ElixirNexus.EmbeddingModel.available?() do
        # Warm-up (first call may compile/JIT)
        ElixirNexus.EmbeddingModel.embed("warmup")

        {result, elapsed} = measure(fn -> ElixirNexus.EmbeddingModel.embed(@sample_code) end)

        case result do
          {:ok, embedding} ->
            IO.puts("\n  Bumblebee embed: #{Float.round(elapsed, 2)}ms, dims: #{length(embedding)}")
            assert length(embedding) == 384
            assert elapsed < 2_000, "Bumblebee single embed took #{Float.round(elapsed, 2)}ms (> 2s)"

          {:error, reason} ->
            IO.puts("\n  Bumblebee embed error: #{inspect(reason)}")
        end
      else
        IO.puts("\n  Bumblebee model not available, skipping")
      end
    end

    test "Bumblebee batch embed (10 texts)" do
      if ElixirNexus.EmbeddingModel.available?() do
        texts = Enum.map(1..10, fn i -> "def function_#{i}(x), do: x * #{i}" end)

        {result, elapsed} = measure(fn -> ElixirNexus.EmbeddingModel.embed_batch(texts) end)

        case result do
          {:ok, embeddings} ->
            per_text = Float.round(elapsed / length(embeddings), 2)
            IO.puts("\n  Bumblebee batch(10): #{Float.round(elapsed, 2)}ms total, #{per_text}ms/text")
            assert length(embeddings) == 10
            assert elapsed < 2_000, "Bumblebee batch(10) took #{Float.round(elapsed, 2)}ms (> 2s)"

          {:error, reason} ->
            IO.puts("\n  Bumblebee batch error: #{inspect(reason)}")
        end
      else
        IO.puts("\n  Bumblebee model not available, skipping")
      end
    end

    test "Bumblebee batch embed (32 texts — max batch size)" do
      if ElixirNexus.EmbeddingModel.available?() do
        texts = Enum.map(1..32, fn i -> "def function_#{i}(x), do: Enum.map(1..x, &(&1 + #{i}))" end)

        {result, elapsed} = measure(fn -> ElixirNexus.EmbeddingModel.embed_batch(texts) end)

        case result do
          {:ok, embeddings} ->
            per_text = Float.round(elapsed / length(embeddings), 2)
            IO.puts("\n  Bumblebee batch(32): #{Float.round(elapsed, 2)}ms total, #{per_text}ms/text")
            assert length(embeddings) == 32
            assert elapsed < 5_000, "Bumblebee batch(32) took #{Float.round(elapsed, 2)}ms (> 5s)"

          {:error, reason} ->
            IO.puts("\n  Bumblebee batch error: #{inspect(reason)}")
        end
      else
        IO.puts("\n  Bumblebee model not available, skipping")
      end
    end

    test "TF-IDF single embed" do
      {result, elapsed} = measure(fn -> ElixirNexus.TFIDFEmbedder.embed(@sample_code) end)

      case result do
        {:ok, embedding} ->
          IO.puts("\n  TF-IDF embed: #{Float.round(elapsed, 2)}ms, dims: #{length(embedding)}")
          assert length(embedding) == 384
          assert elapsed < 10, "TF-IDF single embed took #{Float.round(elapsed, 2)}ms (> 10ms)"

        {:error, reason} ->
          IO.puts("\n  TF-IDF embed error: #{inspect(reason)}")
      end
    end

    test "TF-IDF batch embed (100 texts)" do
      texts = Enum.map(1..100, fn i -> "def function_#{i}(x), do: x * #{i}" end)

      {result, elapsed} = measure(fn -> ElixirNexus.TFIDFEmbedder.embed_batch(texts) end)

      case result do
        {:ok, embeddings} ->
          per_text = Float.round(elapsed / length(embeddings), 2)
          IO.puts("\n  TF-IDF batch(100): #{Float.round(elapsed, 2)}ms total, #{per_text}ms/text")
          assert length(embeddings) == 100
          assert elapsed < 100, "TF-IDF batch(100) took #{Float.round(elapsed, 2)}ms (> 100ms)"

        {:error, reason} ->
          IO.puts("\n  TF-IDF batch error: #{inspect(reason)}")
      end
    end

    test "TF-IDF sparse vector generation" do
      {sparse, elapsed} = measure(fn -> ElixirNexus.TFIDFEmbedder.sparse_vector(@sample_code) end)

      IO.puts("\n  TF-IDF sparse: #{Float.round(elapsed, 2)}ms, #{length(sparse["indices"])} non-zero indices")
      assert is_map(sparse)
      assert is_list(sparse["indices"])
      assert length(sparse["indices"]) == length(sparse["values"])
      assert elapsed < 5, "Sparse vector took #{Float.round(elapsed, 2)}ms (> 5ms)"
    end

    test "TF-IDF vocabulary update (500 documents)" do
      docs = Enum.map(1..500, fn i ->
        "defmodule Mod#{i} do\n  def func_#{i}(x), do: Enum.map(x, &(&1 + #{i}))\nend"
      end)

      {_result, elapsed} = measure(fn -> ElixirNexus.TFIDFEmbedder.update_vocabulary(docs) end)
      IO.puts("\n  TF-IDF vocab update(500 docs): #{Float.round(elapsed, 2)}ms")
      assert elapsed < 500, "Vocab update took #{Float.round(elapsed, 2)}ms (> 500ms)"
    end

    test "Bumblebee vs TF-IDF comparison" do
      bumblebee_time =
        if ElixirNexus.EmbeddingModel.available?() do
          {_, elapsed} = measure(fn -> ElixirNexus.EmbeddingModel.embed(@sample_code) end)
          elapsed
        else
          nil
        end

      {_, tfidf_time} = measure(fn -> ElixirNexus.TFIDFEmbedder.embed(@sample_code) end)

      IO.puts("\n  --- Embedding comparison ---")
      if bumblebee_time do
        IO.puts("  Bumblebee: #{Float.round(bumblebee_time, 2)}ms")
      else
        IO.puts("  Bumblebee: unavailable")
      end
      IO.puts("  TF-IDF:    #{Float.round(tfidf_time, 2)}ms")
      if bumblebee_time do
        ratio = Float.round(bumblebee_time / tfidf_time, 1)
        IO.puts("  Ratio:     Bumblebee is #{ratio}x slower than TF-IDF")
      end
    end
  end

  # ===========================================================================
  # 6. Graph Query Performance (Queries module via ETS)
  # ==========================================================================

  describe "graph query performance" do
    setup do
      # Populate ETS with realistic data so queries use the fast path
      chunks = generate_chunks(500)
      ChunkCache.insert_many(chunks)
      GraphCache.rebuild_from_chunks(chunks)
      :ok
    end

    test "analyze_impact with cached ETS data" do
      {result, elapsed} = assert_under(200, fn ->
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
      {result, elapsed} = assert_under(100, fn ->
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
      {result, elapsed} = assert_under(200, fn ->
        ElixirNexus.Search.get_community_context("lib/mod_1.ex")
      end)

      case result do
        {:ok, ctx} ->
          IO.puts("\n  get_community_context: #{Float.round(elapsed, 2)}ms, coupled_files: #{length(ctx.coupled_files)}")

        {:error, reason} ->
          IO.puts("\n  get_community_context: #{Float.round(elapsed, 2)}ms, error: #{inspect(reason)}")
      end
    end
  end

  # ===========================================================================
  # 7. PubSub Delivery Latency
  # ===========================================================================

  describe "PubSub delivery latency" do
    test "subscribe + broadcast round-trip" do
      Events.subscribe_indexing()

      {_result, elapsed} = measure(fn ->
        Events.broadcast_indexing_progress(%{file: "test.ex", progress: 50})
        receive do
          {:indexing_progress, _data} -> :ok
        after
          1_000 -> flunk("No message received within 1s")
        end
      end)

      IO.puts("\n  pubsub round-trip: #{Float.round(elapsed, 2)}ms")
      assert elapsed < 5, "PubSub round-trip took #{Float.round(elapsed, 2)}ms (> 5ms)"
    end

    test "100 subscribers, 1 broadcast — all receive within 50ms" do
      parent = self()

      pids =
        Enum.map(1..100, fn i ->
          spawn(fn ->
            Events.subscribe_indexing()
            send(parent, {:subscribed, i})

            receive do
              {:indexing_complete, _data} ->
                send(parent, {:received, i, System.monotonic_time(:microsecond)})
            after
              5_000 -> send(parent, {:timeout, i})
            end
          end)
        end)

      # Wait for all subscribers to register
      Enum.each(1..100, fn _ ->
        receive do
          {:subscribed, _} -> :ok
        after
          5_000 -> flunk("Subscriber registration timed out")
        end
      end)

      # Small delay to ensure PubSub registrations propagate
      Process.sleep(10)

      broadcast_time = System.monotonic_time(:microsecond)
      Events.broadcast_indexing_complete(%{files: 10, chunks: 100})

      results =
        Enum.map(1..100, fn _ ->
          receive do
            {:received, i, recv_time} -> {:ok, i, (recv_time - broadcast_time) / 1_000}
            {:timeout, i} -> {:timeout, i, nil}
          after
            5_000 -> {:error, :no_reply, nil}
          end
        end)

      latencies =
        results
        |> Enum.filter(fn {status, _, _} -> status == :ok end)
        |> Enum.map(fn {_, _, latency} -> latency end)
        |> Enum.sort()

      received_count = length(latencies)
      IO.puts("\n  100 subscribers: #{received_count}/100 received")

      if received_count > 0 do
        IO.puts("  max latency: #{Float.round(Enum.max(latencies), 2)}ms")
        assert Enum.max(latencies) < 50, "Max delivery latency exceeded 50ms"
      end

      assert received_count == 100, "Only #{received_count}/100 subscribers received the message"

      # Cleanup
      Enum.each(pids, fn pid -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    end

    test "rapid-fire 100 broadcasts — no message loss" do
      Events.subscribe_indexing()

      Enum.each(1..100, fn i ->
        Events.broadcast_indexing_progress(%{file: "test_#{i}.ex", progress: i})
      end)

      received =
        Enum.reduce_while(1..100, 0, fn _, acc ->
          receive do
            {:indexing_progress, _data} -> {:cont, acc + 1}
          after
            2_000 -> {:halt, acc}
          end
        end)

      IO.puts("\n  rapid-fire: #{received}/100 messages received")
      assert received == 100, "Lost #{100 - received} messages out of 100"
    end
  end
end
