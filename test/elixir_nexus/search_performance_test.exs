defmodule ElixirNexus.SearchPerformanceTest do
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

    test "Ollama single embed" do
      if ElixirNexus.EmbeddingModel.available?() do
        # Warm-up (first call may compile/JIT)
        ElixirNexus.EmbeddingModel.embed("warmup")

        {result, elapsed} = measure(fn -> ElixirNexus.EmbeddingModel.embed(@sample_code) end)

        case result do
          {:ok, embedding} ->
            IO.puts("\n  Ollama embed: #{Float.round(elapsed, 2)}ms, dims: #{length(embedding)}")
            assert length(embedding) == 768
            assert elapsed < 2_000, "Ollama single embed took #{Float.round(elapsed, 2)}ms (> 2s)"

          {:error, reason} ->
            IO.puts("\n  Ollama embed error: #{inspect(reason)}")
        end
      else
        IO.puts("\n  Ollama model not available, skipping")
      end
    end

    test "Ollama batch embed (10 texts)" do
      if ElixirNexus.EmbeddingModel.available?() do
        texts = Enum.map(1..10, fn i -> "def function_#{i}(x), do: x * #{i}" end)

        {result, elapsed} = measure(fn -> ElixirNexus.EmbeddingModel.embed_batch(texts) end)

        case result do
          {:ok, embeddings} ->
            per_text = Float.round(elapsed / length(embeddings), 2)
            IO.puts("\n  Ollama batch(10): #{Float.round(elapsed, 2)}ms total, #{per_text}ms/text")
            assert length(embeddings) == 10
            assert elapsed < 2_000, "Ollama batch(10) took #{Float.round(elapsed, 2)}ms (> 2s)"

          {:error, reason} ->
            IO.puts("\n  Ollama batch error: #{inspect(reason)}")
        end
      else
        IO.puts("\n  Ollama model not available, skipping")
      end
    end

    test "Ollama batch embed (32 texts — max batch size)" do
      if ElixirNexus.EmbeddingModel.available?() do
        texts = Enum.map(1..32, fn i -> "def function_#{i}(x), do: Enum.map(1..x, &(&1 + #{i}))" end)

        {result, elapsed} = measure(fn -> ElixirNexus.EmbeddingModel.embed_batch(texts) end)

        case result do
          {:ok, embeddings} ->
            per_text = Float.round(elapsed / length(embeddings), 2)
            IO.puts("\n  Ollama batch(32): #{Float.round(elapsed, 2)}ms total, #{per_text}ms/text")
            assert length(embeddings) == 32
            assert elapsed < 5_000, "Ollama batch(32) took #{Float.round(elapsed, 2)}ms (> 5s)"

          {:error, reason} ->
            IO.puts("\n  Ollama batch error: #{inspect(reason)}")
        end
      else
        IO.puts("\n  Ollama model not available, skipping")
      end
    end

    test "TF-IDF single embed" do
      {result, elapsed} = measure(fn -> ElixirNexus.TFIDFEmbedder.embed(@sample_code) end)

      case result do
        {:ok, embedding} ->
          IO.puts("\n  TF-IDF embed: #{Float.round(elapsed, 2)}ms, dims: #{length(embedding)}")
          assert length(embedding) == 768
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
      docs =
        Enum.map(1..500, fn i ->
          "defmodule Mod#{i} do\n  def func_#{i}(x), do: Enum.map(x, &(&1 + #{i}))\nend"
        end)

      {_result, elapsed} = measure(fn -> ElixirNexus.TFIDFEmbedder.update_vocabulary(docs) end)
      IO.puts("\n  TF-IDF vocab update(500 docs): #{Float.round(elapsed, 2)}ms")
      assert elapsed < 500, "Vocab update took #{Float.round(elapsed, 2)}ms (> 500ms)"
    end

    test "Ollama vs TF-IDF comparison" do
      ollama_time =
        if ElixirNexus.EmbeddingModel.available?() do
          {_, elapsed} = measure(fn -> ElixirNexus.EmbeddingModel.embed(@sample_code) end)
          elapsed
        else
          nil
        end

      {_, tfidf_time} = measure(fn -> ElixirNexus.TFIDFEmbedder.embed(@sample_code) end)

      IO.puts("\n  --- Embedding comparison ---")

      if ollama_time do
        IO.puts("  Ollama: #{Float.round(ollama_time, 2)}ms")
      else
        IO.puts("  Ollama: unavailable")
      end

      IO.puts("  TF-IDF:    #{Float.round(tfidf_time, 2)}ms")

      if ollama_time do
        ratio = Float.round(ollama_time / tfidf_time, 1)
        IO.puts("  Ratio:     Ollama is #{ratio}x slower than TF-IDF")
      end
    end
  end
end
