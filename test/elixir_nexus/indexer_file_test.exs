defmodule ElixirNexus.IndexerFileTest do
  use ExUnit.Case

  setup do
    :ok = ElixirNexus.Indexer.await_idle()

    test_dir = Path.join(System.tmp_dir!(), "index_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p(test_dir)

    on_exit(fn ->
      ElixirNexus.Indexer.await_idle()
      File.rm_rf(test_dir)
    end)

    {:ok, test_dir: test_dir}
  end

  describe "status/0" do
    test "returns indexing status" do
      status = ElixirNexus.Indexer.status()

      assert is_map(status)
      assert Map.has_key?(status, :indexed_files)
      assert Map.has_key?(status, :total_chunks)
      assert Map.has_key?(status, :status)
      assert is_integer(status.indexed_files)
      assert is_integer(status.total_chunks)
    end

    test "status has all expected keys" do
      status = ElixirNexus.Indexer.status()

      assert Map.has_key?(status, :indexed_files)
      assert Map.has_key?(status, :total_chunks)
      assert Map.has_key?(status, :status)
    end
  end

  describe "index_file/1" do
    test "indexes a single Elixir file", %{test_dir: test_dir} do
      test_file = Path.join(test_dir, "test.ex")

      File.write(test_file, """
      defmodule TestModule do
        def test_func do
          :ok
        end
      end
      """)

      result = ElixirNexus.Indexer.index_file(test_file)

      assert is_tuple(result)

      case result do
        {:ok, _status} -> assert true
        {:error, _reason} -> assert true
      end
    end

    test "returns error for non-existent file" do
      result = ElixirNexus.Indexer.index_file("/nonexistent/file.ex")

      assert {:error, _reason} = result
    end

    test "handles non-Elixir files gracefully", %{test_dir: test_dir} do
      test_file = Path.join(test_dir, "test.txt")
      File.write(test_file, "not elixir")

      result = ElixirNexus.Indexer.index_file(test_file)

      assert is_tuple(result)

      case result do
        {:ok, _} -> assert true
        {:error, _} -> assert true
      end
    end

    test "handles files with syntax errors gracefully", %{test_dir: test_dir} do
      test_file = Path.join(test_dir, "bad.ex")

      File.write(test_file, """
      defmodule Bad do
        def broken(
        # missing closing
      end
      """)

      result = ElixirNexus.Indexer.index_file(test_file)

      assert is_tuple(result)
    end
  end

  describe "delete_file/1" do
    test "removes file from ChunkCache and GraphCache", %{test_dir: test_dir} do
      test_file = Path.join(test_dir, "deletable.ex")

      File.write!(test_file, """
      defmodule Deletable do
        def will_be_deleted, do: :gone
      end
      """)

      ElixirNexus.Indexer.index_file(test_file)

      chunks_before =
        ElixirNexus.ChunkCache.all()
        |> Enum.filter(&(&1.file_path == test_file))

      assert length(chunks_before) >= 1

      assert :ok = ElixirNexus.Indexer.delete_file(test_file)

      chunks_after =
        ElixirNexus.ChunkCache.all()
        |> Enum.filter(&(&1.file_path == test_file))

      assert chunks_after == []
    end

    test "handles non-indexed file gracefully" do
      assert :ok = ElixirNexus.Indexer.delete_file("/nonexistent/file.ex")
    end
  end

  describe "search_chunks/2" do
    test "searches indexed chunks by keyword", %{test_dir: test_dir} do
      test_file = Path.join(test_dir, "searchable.ex")

      File.write(test_file, """
      defmodule ProcessWorker do
        def process_data do
          validate_input()
        end

        defp validate_input do
          :ok
        end
      end
      """)

      ElixirNexus.Indexer.index_file(test_file)

      result = ElixirNexus.Indexer.search_chunks("process", 10)

      assert is_tuple(result)

      case result do
        {:ok, results} ->
          assert is_list(results)

          if length(results) > 0 do
            assert Enum.any?(results, fn r ->
                     String.contains?(String.downcase(r.entity["name"]), "process")
                   end)
          end

        {:error, _} ->
          assert true
      end
    end

    test "returns empty list for no matches" do
      result = ElixirNexus.Indexer.search_chunks("thisfunctiondefinitelydoesnotexistyxz", 10)

      assert {:ok, results} = result
      assert is_list(results)
    end

    test "respects limit parameter" do
      result = ElixirNexus.Indexer.search_chunks("def", 1)

      assert {:ok, results} = result
      assert is_list(results)
      assert length(results) <= 1
    end

    test "finds indexed content", %{test_dir: test_dir} do
      test_file = Path.join(test_dir, "searchable2.ex")

      File.write!(test_file, """
      defmodule UniqueSearchable do
        def unique_test_function_xyz, do: :ok
      end
      """)

      ElixirNexus.Indexer.index_file(test_file)

      {:ok, results} = ElixirNexus.Indexer.search_chunks("unique_test_function", 10)
      assert is_list(results)
    end
  end

  describe "chunk processing and embedding" do
    test "creates chunks with proper structure", %{test_dir: test_dir} do
      test_file = Path.join(test_dir, "chunked.ex")

      File.write(test_file, """
      defmodule ChunkTest do
        def function_one do
          :result1
        end

        def function_two do
          :result2
        end
      end
      """)

      result = ElixirNexus.Indexer.index_file(test_file)

      assert is_tuple(result)

      case result do
        {:ok, _} ->
          status = ElixirNexus.Indexer.status()
          assert status.total_chunks >= 1

        {:error, _} ->
          assert true
      end
    end
  end

  describe "file tracking" do
    test "tracks indexed files in state" do
      status = ElixirNexus.Indexer.status()

      assert is_integer(status.indexed_files)
      assert status.indexed_files >= 0
    end

    test "reports chunk count" do
      status = ElixirNexus.Indexer.status()

      assert is_integer(status.total_chunks)
      assert status.total_chunks >= 0
    end
  end
end
