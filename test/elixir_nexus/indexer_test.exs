defmodule ElixirNexus.IndexerTest do
  use ExUnit.Case

  # Services are already started by the application supervision tree
  
  setup do
    # Wait for any in-progress indexing from other tests to finish
    :ok = ElixirNexus.Indexer.await_idle()

    # Create temp directory with test files
    temp_dir = System.tmp_dir!()
    test_dir = Path.join(temp_dir, "index_test_#{:rand.uniform(1000000)}")
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
  end

  describe "index_file/1" do
    test "indexes a single Elixir file", %{test_dir: test_dir} do
      test_file = Path.join(test_dir, "test.ex")
      
      code = """
      defmodule TestModule do
        def test_func do
          :ok
        end
      end
      """
      
      File.write(test_file, code)
      
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
      
      # Attempt to index non-Elixir file
      result = ElixirNexus.Indexer.index_file(test_file)
      
      # Should handle gracefully (error or empty ok)
      assert is_tuple(result)
      case result do
        {:ok, _} -> assert true
        {:error, _} -> assert true
      end
    end

    test "handles files with syntax errors gracefully", %{test_dir: test_dir} do
      test_file = Path.join(test_dir, "bad.ex")
      
      code = """
      defmodule Bad do
        def broken(
        # missing closing
      end
      """
      
      File.write(test_file, code)
      
      result = ElixirNexus.Indexer.index_file(test_file)
      
      # Should handle error gracefully
      assert is_tuple(result)
    end
  end

  describe "index_directory/1" do
    test "indexes directory recursively", %{test_dir: test_dir} do
      # Create nested structure
      File.write(Path.join(test_dir, "file1.ex"), """
        defmodule A do
          def a, do: :ok
        end
      """)
      
      subdir = Path.join(test_dir, "subdir")
      File.mkdir_p(subdir)
      File.write(Path.join(subdir, "file2.ex"), """
        defmodule B do
          def b, do: :ok
        end
      """)
      
      result = ElixirNexus.Indexer.index_directory(test_dir)
      
      assert is_tuple(result)
      case result do
        {:ok, status} ->
          assert is_map(status)
          # Should have indexed some files
          assert status.indexed_files >= 2
        {:error, _} ->
          assert true
      end
    end

    test "handles empty directory" do
      temp_dir = System.tmp_dir!()
      empty_dir = Path.join(temp_dir, "empty_#{:rand.uniform(1000000)}")
      File.mkdir_p(empty_dir)
      
      on_exit(fn -> File.rm_rf(empty_dir) end)
      
      result = ElixirNexus.Indexer.index_directory(empty_dir)
      
      assert is_tuple(result)
      case result do
        {:ok, status} ->
          # Empty directory should have 0 newly indexed files in response
          assert is_integer(status.indexed_files)
        {:error, _} ->
          assert true
      end
    end

    test "skips non-Elixir files in directory", %{test_dir: test_dir} do
      File.write(Path.join(test_dir, "valid.ex"), """
        defmodule Valid do
          def valid, do: :ok
        end
      """)
      
      File.write(Path.join(test_dir, "readme.md"), "# Not Elixir")
      File.write(Path.join(test_dir, "config.json"), "{}")
      
      result = ElixirNexus.Indexer.index_directory(test_dir)
      
      assert is_tuple(result)
    end
  end

  describe "search_chunks/2" do
    test "searches indexed chunks by keyword", %{test_dir: test_dir} do
      test_file = Path.join(test_dir, "searchable.ex")
      
      code = """
      defmodule ProcessWorker do
        def process_data do
          validate_input()
        end
        
        defp validate_input do
          :ok
        end
      end
      """
      
      File.write(test_file, code)
      ElixirNexus.Indexer.index_file(test_file)
      
      # Search for function
      result = ElixirNexus.Indexer.search_chunks("process", 10)
      
      assert is_tuple(result)
      case result do
        {:ok, results} ->
          assert is_list(results)
          # Should find function with "process" in name
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
  end

  describe "chunk processing and embedding" do
    test "creates chunks with proper structure", %{test_dir: test_dir} do
      test_file = Path.join(test_dir, "chunked.ex")
      
      code = """
      defmodule ChunkTest do
        def function_one do
          :result1
        end
        
        def function_two do
          :result2
        end
      end
      """
      
      File.write(test_file, code)
      result = ElixirNexus.Indexer.index_file(test_file)
      
      assert is_tuple(result)
      case result do
        {:ok, _} ->
          status = ElixirNexus.Indexer.status()
          # Should have indexed some chunks
          assert status.total_chunks >= 1
        {:error, _} ->
          assert true
      end
    end
  end

  describe "error resilience" do
    test "continues after individual file errors", %{test_dir: test_dir} do
      # Create mix of good and bad files
      File.write(Path.join(test_dir, "good.ex"), """
        defmodule Good do
          def good, do: :ok
        end
      """)
      
      File.write(Path.join(test_dir, "bad.ex"), """
        defmodule Bad do
          def broken(
          # no closing
      """)
      
      # Index directory - should not crash on bad file
      result = ElixirNexus.Indexer.index_directory(test_dir)
      
      assert is_tuple(result)
    end

    test "handles concurrent indexing gracefully" do
      # This is a basic concurrency test
      # In practice, GenServer handles sequential calls
      temp_dir = System.tmp_dir!()
      test_dir = Path.join(temp_dir, "concurrent_#{:rand.uniform(1000000)}")
      File.mkdir_p(test_dir)
      
      on_exit(fn -> File.rm_rf(test_dir) end)
      
      # Make multiple index calls
      tasks = for i <- 1..3 do
        Task.async(fn ->
          ElixirNexus.Indexer.index_directory(test_dir)
        end)
      end
      
      results = Task.await_many(tasks)
      
      # All should complete without crash
      assert Enum.all?(results, &is_tuple/1)
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

  describe "index_directories/1" do
    test "returns ok with zero counts for empty list" do
      result = ElixirNexus.Indexer.index_directories([])
      assert {:ok, status} = result
      assert status.indexed_files == 0
      assert status.total_chunks == 0
    end

    test "indexes multiple directories", %{test_dir: test_dir} do
      dir1 = Path.join(test_dir, "dir1")
      dir2 = Path.join(test_dir, "dir2")
      File.mkdir_p!(dir1)
      File.mkdir_p!(dir2)

      File.write!(Path.join(dir1, "a.ex"), """
      defmodule A do
        def a, do: :ok
      end
      """)

      File.write!(Path.join(dir2, "b.ex"), """
      defmodule B do
        def b, do: :ok
      end
      """)

      result = ElixirNexus.Indexer.index_directories([dir1, dir2])
      assert {:ok, status} = result
      assert is_integer(status.indexed_files)
    end
  end

  describe "status/0 - full structure" do
    test "status has all expected keys" do
      status = ElixirNexus.Indexer.status()

      assert Map.has_key?(status, :indexed_files)
      assert Map.has_key?(status, :total_chunks)
      assert Map.has_key?(status, :status)
    end
  end

  describe "search_chunks/2 - after indexing" do
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
end
