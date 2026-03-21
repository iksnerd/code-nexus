defmodule ElixirNexus.HybridSearchTest do
  @moduledoc """
  Integration tests for hybrid search quality.
  Tests that Qdrant RRF fusion + graph re-ranking produces relevant results.
  These tests are resilient to collection state — they skip assertions when
  the collection has been reset by other tests.
  """
  use ExUnit.Case

  describe "search quality - exact name matches" do
    test "exact function name ranks highly when data is available" do
      case ElixirNexus.Search.search_code("search_code", 10) do
        {:ok, results} when results != [] ->
          names = Enum.map(results, & &1.entity["name"])
          # If we have real data indexed, the exact match should be present
          if Enum.any?(names, &(&1 == "search_code")) do
            top5 = Enum.take(names, 5)
            assert "search_code" in top5, "Expected 'search_code' in top 5, got: #{inspect(top5)}"
          end

        {:ok, []} ->
          :ok
      end
    end
  end

  describe "search quality - result structure" do
    test "results contain required fields" do
      case ElixirNexus.Search.search_code("function", 3) do
        {:ok, results} when results != [] ->
          for result <- results do
            assert Map.has_key?(result, :score)
            assert Map.has_key?(result, :entity)
            assert Map.has_key?(result, :id)
            assert is_number(result.score)
            assert is_map(result.entity)
            assert result.entity["name"] != nil
            assert result.entity["entity_type"] != nil
          end

        {:ok, []} ->
          :ok
      end
    end

    test "results include language field in entity" do
      case ElixirNexus.Search.search_code("module", 3) do
        {:ok, results} when results != [] ->
          for result <- results do
            assert Map.has_key?(result.entity, "language")
          end

        {:ok, []} ->
          :ok
      end
    end

    test "results are sorted by score descending" do
      case ElixirNexus.Search.search_code("search", 10) do
        {:ok, results} when length(results) > 1 ->
          scores = Enum.map(results, & &1.score)
          assert scores == Enum.sort(scores, :desc),
            "Results not sorted by score: #{inspect(scores)}"

        _ ->
          :ok
      end
    end

    test "results are deduplicated by name+type" do
      case ElixirNexus.Search.search_code("handle_call", 20) do
        {:ok, results} when results != [] ->
          keys = Enum.map(results, fn r ->
            "#{r.entity["name"]}::#{r.entity["entity_type"]}"
          end)
          assert keys == Enum.uniq(keys), "Duplicate results found"

        {:ok, []} ->
          :ok
      end
    end
  end

  describe "search quality - edge cases" do
    test "empty query does not crash" do
      result = ElixirNexus.Search.search_code("", 5)
      assert {:ok, _} = result
    end

    test "gibberish query returns empty or low-score results" do
      case ElixirNexus.Search.search_code("xyzzy_plugh_42_nonsense", 5) do
        {:ok, results} ->
          if results != [] do
            top_score = hd(results).score
            assert top_score < 1.5, "Gibberish query got suspiciously high score: #{top_score}"
          end
      end
    end

    test "special characters in query don't crash" do
      queries = [
        "def foo(bar)",
        "Module.function/2",
        "%{key: value}",
        "@spec :: term()",
        "fn x -> x end"
      ]

      for query <- queries do
        result = ElixirNexus.Search.search_code(query, 3)
        assert {:ok, _} = result, "Query #{inspect(query)} failed"
      end
    end
  end

  describe "scoring - deduplicate" do
    test "keeps highest score per name+type group" do
      results = [
        %{id: 1, score: 0.9, entity: %{"name" => "foo", "entity_type" => "function"}},
        %{id: 2, score: 0.5, entity: %{"name" => "foo", "entity_type" => "function"}},
        %{id: 3, score: 0.8, entity: %{"name" => "bar", "entity_type" => "function"}},
        %{id: 4, score: 0.7, entity: %{"name" => "foo", "entity_type" => "module"}}
      ]

      deduped = ElixirNexus.Search.Scoring.deduplicate(results)
      assert length(deduped) == 3

      foo_fn = Enum.find(deduped, &(&1.entity["name"] == "foo" and &1.entity["entity_type"] == "function"))
      assert foo_fn.score == 0.9

      foo_mod = Enum.find(deduped, &(&1.entity["name"] == "foo" and &1.entity["entity_type"] == "module"))
      assert foo_mod.score == 0.7
    end
  end

  describe "format_payload" do
    test "formats valid payload with all fields" do
      payload = %{
        "file_path" => "lib/test.ex",
        "entity_type" => "function",
        "name" => "test",
        "start_line" => 1,
        "end_line" => 10,
        "content" => "code",
        "visibility" => "public",
        "parameters" => ["a"],
        "calls" => ["helper"],
        "is_a" => ["GenServer"],
        "contains" => [],
        "language" => "elixir"
      }

      formatted = ElixirNexus.Search.format_payload(payload)
      assert formatted["name"] == "test"
      assert formatted["language"] == "elixir"
      assert formatted["calls"] == ["helper"]
    end

    test "formats nil payload with defaults" do
      formatted = ElixirNexus.Search.format_payload(nil)
      assert formatted["name"] == "Unknown"
      assert formatted["entity_type"] == "unknown"
      assert formatted["language"] == nil
      assert formatted["calls"] == []
    end
  end
end
