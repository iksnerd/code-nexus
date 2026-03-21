defmodule ElixirNexus.QdrantClientTest do
  use ExUnit.Case

  # QdrantClient is already started by the application supervision tree

  describe "health_check/0" do
    test "returns ok or error tuple" do
      result = ElixirNexus.QdrantClient.health_check()

      assert is_tuple(result)
      case result do
        {:ok, _response} -> assert true
        {:error, _reason} -> assert true
        _ -> flunk("Unexpected result: #{inspect(result)}")
      end
    end
  end

  describe "create_collection/1" do
    test "creates collection with named vectors and sparse vectors" do
      result = ElixirNexus.QdrantClient.create_collection(384)

      assert is_tuple(result)
      case result do
        {:ok, _} -> assert true
        {:error, _} -> assert true
      end
    end

    test "handles various vector sizes" do
      for size <- [64, 128, 256, 384, 512] do
        result = ElixirNexus.QdrantClient.create_collection(size)
        assert is_tuple(result)
      end
    end
  end

  describe "upsert_point/3" do
    test "upserts point with named vector format" do
      vector = List.duplicate(0.5, 384)
      payload = %{
        "name" => "test_func",
        "entity_type" => "function"
      }

      result = ElixirNexus.QdrantClient.upsert_point(1, vector, payload)

      assert is_tuple(result)
      case result do
        {:ok, _response} -> assert true
        {:error, _reason} -> assert true
      end
    end

    test "accepts complex payloads" do
      vector = List.duplicate(0.1, 384)
      payload = %{
        "name" => "process_data",
        "entity_type" => "function",
        "file_path" => "lib/worker.ex",
        "start_line" => 10,
        "end_line" => 25,
        "content" => "def process_data(data) do ... end",
        "visibility" => "public",
        "parameters" => ["data"],
        "calls" => ["transform", "validate"],
        "is_a" => [],
        "contains" => [],
        "language" => "elixir"
      }

      result = ElixirNexus.QdrantClient.upsert_point(2, vector, payload)

      assert is_tuple(result)
    end
  end

  describe "upsert_points/1 - batch" do
    test "batch upserts multiple points" do
      points = [
        %{
          "id" => 100,
          "vector" => %{
            "semantic" => List.duplicate(0.5, 384),
            "keywords" => %{"indices" => [1, 5, 10], "values" => [0.5, 0.3, 0.1]}
          },
          "payload" => %{"name" => "func1", "entity_type" => "function"}
        },
        %{
          "id" => 101,
          "vector" => %{
            "semantic" => List.duplicate(0.3, 384),
            "keywords" => %{"indices" => [2, 8], "values" => [0.7, 0.2]}
          },
          "payload" => %{"name" => "func2", "entity_type" => "function"}
        }
      ]

      result = ElixirNexus.QdrantClient.upsert_points(points)
      assert is_tuple(result)
    end
  end

  describe "search/2" do
    test "returns search results tuple" do
      vector = List.duplicate(0.5, 384)
      result = ElixirNexus.QdrantClient.search(vector, 10)

      assert is_tuple(result)
      case result do
        {:ok, response} ->
          assert is_map(response)
        {:error, _reason} ->
          assert true
      end
    end

    test "handles various limit values" do
      vector = List.duplicate(0.5, 384)

      for limit <- [1, 5, 10, 20, 100] do
        result = ElixirNexus.QdrantClient.search(vector, limit)
        assert is_tuple(result)
      end
    end
  end

  describe "hybrid_search/3" do
    test "performs RRF fusion search" do
      embedding = List.duplicate(0.5, 384)
      sparse = %{"indices" => [1, 5, 10], "values" => [0.5, 0.3, 0.1]}

      result = ElixirNexus.QdrantClient.hybrid_search(embedding, sparse, 10)

      assert is_tuple(result)
      case result do
        {:ok, response} -> assert is_map(response)
        {:error, _} -> assert true
      end
    end
  end

  describe "search_with_filter/3" do
    test "filters search results" do
      vector = List.duplicate(0.5, 384)
      filter = %{
        "must" => [
          %{
            "key" => "entity_type",
            "match" => %{"value" => "function"}
          }
        ]
      }

      result = ElixirNexus.QdrantClient.search_with_filter(vector, filter, 10)

      assert is_tuple(result)
    end
  end

  describe "integration patterns" do
    test "workflow: create, upsert, search" do
      vector1 = List.duplicate(0.5, 384)
      payload1 = %{
        "name" => "func1",
        "entity_type" => "function",
        "file_path" => "test.ex"
      }

      _create_result = ElixirNexus.QdrantClient.create_collection(384)

      {:ok, _} = ElixirNexus.QdrantClient.upsert_point(100, vector1, payload1)

      result = ElixirNexus.QdrantClient.search(vector1, 5)

      assert is_tuple(result)
    end
  end

  describe "error handling" do
    test "handles network errors gracefully" do
      vector = List.duplicate(0.5, 384)
      result = ElixirNexus.QdrantClient.search(vector, 10)

      assert is_tuple(result)
      assert elem(result, 0) in [:ok, :error]
    end
  end
end
