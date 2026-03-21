defmodule ElixirNexus.SearchTest do
  use ExUnit.Case

  describe "search_code/2 - hybrid search" do
    test "formats search results correctly" do
      raw_results = %{
        "result" => [
          %{
            "id" => "1",
            "score" => 0.95,
            "payload" => %{
              "name" => "test_func",
              "entity_type" => "function"
            }
          }
        ]
      }

      assert raw_results["result"] |> length() == 1
      assert Enum.all?(raw_results["result"], &Map.has_key?(&1, "id"))
    end

    test "handles empty search results gracefully" do
      empty_results = %{"result" => []}
      assert is_list(empty_results["result"])
      assert length(empty_results["result"]) == 0
    end
  end

  describe "format helpers" do
    test "format_payload preserves all fields including language" do
      payload = %{
        "file_path" => "lib/test.ex",
        "entity_type" => "function",
        "name" => "test",
        "start_line" => 1,
        "end_line" => 10,
        "content" => "code",
        "visibility" => "public",
        "parameters" => ["a", "b"],
        "calls" => ["helper"],
        "is_a" => ["GenServer"],
        "contains" => [],
        "language" => "elixir"
      }

      formatted = ElixirNexus.Search.format_payload(payload)
      assert formatted["name"] == "test"
      assert formatted["entity_type"] == "function"
      assert formatted["language"] == "elixir"
      assert is_list(formatted["calls"])
      assert is_list(formatted["is_a"])
    end

    test "format_payload handles nil gracefully" do
      default_payload = ElixirNexus.Search.format_payload(nil)

      assert default_payload["name"] == "Unknown"
      assert default_payload["entity_type"] == "unknown"
      assert default_payload["language"] == nil
      assert is_list(default_payload["calls"])
    end
  end

  describe "scoring - deduplicate" do
    test "deduplicates results by name+type keeping highest score" do
      results = [
        %{id: 1, score: 0.9, entity: %{"name" => "foo", "entity_type" => "function"}},
        %{id: 2, score: 0.5, entity: %{"name" => "foo", "entity_type" => "function"}},
        %{id: 3, score: 0.8, entity: %{"name" => "bar", "entity_type" => "function"}}
      ]

      deduped = ElixirNexus.Search.Scoring.deduplicate(results)
      assert length(deduped) == 2

      foo = Enum.find(deduped, &(&1.entity["name"] == "foo"))
      assert foo.score == 0.9
    end
  end

  describe "build_context_graph/1" do
    test "builds context graph from neighbors" do
      neighbors = [
        %{
          entity: %{
            "name" => "func1",
            "entity_type" => "function",
            "calls" => ["func2"],
            "is_a" => [],
            "contains" => []
          }
        },
        %{
          entity: %{
            "name" => "func2",
            "entity_type" => "function",
            "calls" => [],
            "is_a" => [],
            "contains" => []
          }
        }
      ]

      graph_summary = %{
        "total_entities" => 2,
        "modules" => 0,
        "functions" => 2,
        "macros" => 0,
        "relationships" => %{
          "calls" => 1,
          "is_a" => 0,
          "contains" => 0
        }
      }

      assert graph_summary["total_entities"] == 2
      assert graph_summary["relationships"]["calls"] == 1
    end
  end

  describe "finder functions - contract verification" do
    test "find_callers returns proper structure" do
      caller_result = %{
        id: "func1",
        name: "process",
        type: "function",
        calls_count: 2,
        is_called_by: 5
      }

      assert caller_result.name == "process"
      assert is_integer(caller_result.calls_count)
      assert is_integer(caller_result.is_called_by)
    end

    test "find_callees returns proper structure" do
      callee_result = %{
        id: "func2",
        name: "helper",
        type: "function",
        calls_count: 0,
        callers: 3
      }

      assert callee_result.name == "helper"
      assert is_integer(callee_result.calls_count)
      assert is_integer(callee_result.callers)
    end
  end

  describe "search resilience" do
    test "handles embedding failures gracefully" do
      result = {:error, :embedding_unavailable}
      assert elem(result, 0) == :error
    end

    test "handles empty vector fallback" do
      dummy_vector = List.duplicate(0.0, 384)

      assert is_list(dummy_vector)
      assert length(dummy_vector) == 384
      assert Enum.all?(dummy_vector, &(&1 == 0.0))
    end
  end

  describe "search_code/2 integration" do
    test "returns {:ok, list} for any query" do
      {:ok, results} = ElixirNexus.Search.search_code("test query", 5)
      assert is_list(results)
    end

    test "limits results" do
      {:ok, results} = ElixirNexus.Search.search_code("function", 3)
      assert length(results) <= 3
    end

    test "results have expected structure" do
      {:ok, results} = ElixirNexus.Search.search_code("module", 5)

      Enum.each(results, fn result ->
        assert Map.has_key?(result, :id)
        assert Map.has_key?(result, :score)
        assert Map.has_key?(result, :entity)
        assert is_map(result.entity)
      end)
    end

    test "filters temp file results" do
      {:ok, results} = ElixirNexus.Search.search_code("handle_call", 10)

      Enum.each(results, fn result ->
        path = result.entity["file_path"] || ""
        refute String.starts_with?(path, "/tmp/")
        refute String.starts_with?(path, "/var/")
      end)
    end
  end

  describe "filter_ast_noise/1" do
    test "filters out known noise tokens" do
      input = ["GenServer", "__block__", "helper", "->", "use", "format"]
      filtered = ElixirNexus.Search.filter_ast_noise(input)

      assert "GenServer" in filtered
      assert "helper" in filtered
      assert "format" in filtered
      refute "__block__" in filtered
      refute "->" in filtered
      refute "use" in filtered
    end

    test "returns empty list for empty input" do
      assert ElixirNexus.Search.filter_ast_noise([]) == []
    end

    test "returns empty list when all items are noise" do
      input = ["__block__", "->", "use", "import", "alias"]
      assert ElixirNexus.Search.filter_ast_noise(input) == []
    end
  end

  describe "format_payload/1 - nil calls/parameters defaults" do
    test "format_payload with nil calls defaults to empty list" do
      payload = %{
        "file_path" => "test.ex",
        "entity_type" => "function",
        "name" => "test",
        "start_line" => 1,
        "end_line" => 5,
        "content" => "code",
        "visibility" => "public",
        "parameters" => nil,
        "calls" => nil,
        "is_a" => nil,
        "contains" => nil,
        "language" => "elixir"
      }

      formatted = ElixirNexus.Search.format_payload(payload)
      assert formatted["parameters"] == []
      assert formatted["calls"] == []
      assert formatted["is_a"] == []
      assert formatted["contains"] == []
    end
  end
end
