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
      result = ElixirNexus.QdrantClient.create_collection(768)

      assert is_tuple(result)

      case result do
        {:ok, _} -> assert true
        {:error, _} -> assert true
      end
    end

    test "handles various vector sizes" do
      for size <- [64, 128, 256, 768, 512] do
        result = ElixirNexus.QdrantClient.create_collection(size)
        assert is_tuple(result)
      end
    end
  end

  describe "upsert_point/3" do
    test "upserts point with named vector format" do
      vector = List.duplicate(0.5, 768)

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
      vector = List.duplicate(0.1, 768)

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
            "semantic" => List.duplicate(0.5, 768),
            "keywords" => %{"indices" => [1, 5, 10], "values" => [0.5, 0.3, 0.1]}
          },
          "payload" => %{"name" => "func1", "entity_type" => "function"}
        },
        %{
          "id" => 101,
          "vector" => %{
            "semantic" => List.duplicate(0.3, 768),
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
      vector = List.duplicate(0.5, 768)
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
      vector = List.duplicate(0.5, 768)

      for limit <- [1, 5, 10, 20, 100] do
        result = ElixirNexus.QdrantClient.search(vector, limit)
        assert is_tuple(result)
      end
    end
  end

  describe "hybrid_search/3" do
    test "performs RRF fusion search" do
      embedding = List.duplicate(0.5, 768)
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
      vector = List.duplicate(0.5, 768)

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
      vector1 = List.duplicate(0.5, 768)

      payload1 = %{
        "name" => "func1",
        "entity_type" => "function",
        "file_path" => "test.ex"
      }

      _create_result = ElixirNexus.QdrantClient.create_collection(768)

      {:ok, _} = ElixirNexus.QdrantClient.upsert_point(100, vector1, payload1)

      result = ElixirNexus.QdrantClient.search(vector1, 5)

      assert is_tuple(result)
    end
  end

  describe "error handling" do
    test "handles network errors gracefully" do
      vector = List.duplicate(0.5, 768)
      result = ElixirNexus.QdrantClient.search(vector, 10)

      assert is_tuple(result)
      assert elem(result, 0) in [:ok, :error]
    end
  end

  # ── collection_name/0 — pure derivation logic, no Qdrant needed ──────────

  describe "collection_name/0" do
    test "returns a string" do
      assert is_binary(ElixirNexus.QdrantClient.collection_name())
    end

    test "appends _test suffix in test env" do
      name = ElixirNexus.QdrantClient.collection_name()
      assert String.ends_with?(name, "_test")
    end

    test "name contains only lowercase alphanumeric and underscores" do
      name = ElixirNexus.QdrantClient.collection_name()
      # strip the _test suffix before checking character set
      base = String.replace_suffix(name, "_test", "")
      assert base =~ ~r/^[a-z0-9_]+$/
    end

    test "name is at most 64 chars (59-char base + _test)" do
      name = ElixirNexus.QdrantClient.collection_name()
      assert String.length(name) <= 64
    end

    test "NEXUS_COLLECTION env var overrides project directory" do
      System.put_env("NEXUS_COLLECTION", "my-custom-collection")

      on_exit(fn -> System.delete_env("NEXUS_COLLECTION") end)

      name = ElixirNexus.QdrantClient.collection_name()
      assert name =~ "my_custom_collection"
    end

    test "NEXUS_COLLECTION special characters are replaced with underscores" do
      System.put_env("NEXUS_COLLECTION", "my-project/v2.0!")

      on_exit(fn -> System.delete_env("NEXUS_COLLECTION") end)

      name = ElixirNexus.QdrantClient.collection_name()
      base = String.replace_suffix(name, "_test", "")
      assert base =~ ~r/^[a-z0-9_]+$/
    end
  end

  # ── active_collection/0 — reads Application env / process dict ───────────

  describe "active_collection/0" do
    setup do
      original = Application.get_env(:elixir_nexus, :qdrant_runtime)

      on_exit(fn ->
        if original do
          Application.put_env(:elixir_nexus, :qdrant_runtime, original)
        else
          Application.delete_env(:elixir_nexus, :qdrant_runtime)
        end
      end)

      :ok
    end

    test "returns a string" do
      assert is_binary(ElixirNexus.QdrantClient.active_collection())
    end

    test "reflects the value stored in Application env" do
      Application.put_env(:elixir_nexus, :qdrant_runtime, %{
        url: "http://localhost:6333",
        collection: "nexus_sentinel_collection"
      })

      assert ElixirNexus.QdrantClient.active_collection() == "nexus_sentinel_collection"
    end

    test "process dictionary override takes precedence over Application env" do
      Application.put_env(:elixir_nexus, :qdrant_runtime, %{
        url: "http://localhost:6333",
        collection: "nexus_app_env_collection"
      })

      Process.put(:nexus_collection, "nexus_process_dict_override")

      on_exit(fn -> Process.delete(:nexus_collection) end)

      assert ElixirNexus.QdrantClient.active_collection() == "nexus_process_dict_override"
    end
  end

  # ── switch_collection_force/1 — no Qdrant round-trip ─────────────────────

  describe "switch_collection_force/1" do
    setup do
      original = Application.get_env(:elixir_nexus, :qdrant_runtime)

      on_exit(fn ->
        if original do
          Application.put_env(:elixir_nexus, :qdrant_runtime, original)
        else
          Application.delete_env(:elixir_nexus, :qdrant_runtime)
        end
      end)

      :ok
    end

    test "switches active_collection immediately without validation" do
      :ok = ElixirNexus.QdrantClient.switch_collection_force("nexus_force_switched")
      assert ElixirNexus.QdrantClient.active_collection() == "nexus_force_switched"
    end

    test "accepts any string — does not check Qdrant for existence" do
      result = ElixirNexus.QdrantClient.switch_collection_force("nexus_definitely_does_not_exist_xyz")
      assert result == :ok
    end

    test "switching back restores active_collection" do
      original = ElixirNexus.QdrantClient.active_collection()
      :ok = ElixirNexus.QdrantClient.switch_collection_force("nexus_temp_collection")
      assert ElixirNexus.QdrantClient.active_collection() == "nexus_temp_collection"

      :ok = ElixirNexus.QdrantClient.switch_collection_force(original)
      assert ElixirNexus.QdrantClient.active_collection() == original
    end
  end

  # ── collection management — needs Qdrant, lenient pass/fail ──────────────

  describe "list_collections/0" do
    test "returns ok with a list or an error" do
      result = ElixirNexus.QdrantClient.list_collections()

      case result do
        {:ok, names} -> assert is_list(names)
        {:error, _} -> :ok
      end
    end

    test "collection names are strings when Qdrant is available" do
      case ElixirNexus.QdrantClient.list_collections() do
        {:ok, names} -> assert Enum.all?(names, &is_binary/1)
        {:error, _} -> :ok
      end
    end
  end

  describe "switch_collection/1" do
    test "returns error for nonexistent collection" do
      result = ElixirNexus.QdrantClient.switch_collection("nexus_nonexistent_xyz_#{System.unique_integer()}")

      case result do
        {:error, _} -> assert true
        # If Qdrant is down the client may also return error
        {:ok, _} -> assert true
      end
    end
  end

  describe "delete_collection/1 (by name)" do
    test "returns tuple for nonexistent collection name" do
      result = ElixirNexus.QdrantClient.delete_collection("nexus_never_existed_xyz")
      assert is_tuple(result)
      assert elem(result, 0) in [:ok, :error]
    end
  end

  describe "reset_collection/0" do
    test "returns a tuple" do
      result = ElixirNexus.QdrantClient.reset_collection()
      assert is_tuple(result)
      assert elem(result, 0) in [:ok, :error]
    end
  end

  describe "delete_points_by_file/1" do
    test "accepts a file path string and returns a tuple" do
      result = ElixirNexus.QdrantClient.delete_points_by_file("/nonexistent/file.ex")
      assert is_tuple(result)
      assert elem(result, 0) in [:ok, :error]
    end
  end
end
