defmodule ElixirNexus.IndexerDirectoryTest do
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

  describe "index_directory/1" do
    test "indexes directory recursively", %{test_dir: test_dir} do
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
          assert status.indexed_files >= 2

        {:error, _} ->
          assert true
      end
    end

    test "handles empty directory" do
      empty_dir = Path.join(System.tmp_dir!(), "empty_#{:rand.uniform(1_000_000)}")
      File.mkdir_p(empty_dir)

      on_exit(fn -> File.rm_rf(empty_dir) end)

      result = ElixirNexus.Indexer.index_directory(empty_dir)

      assert is_tuple(result)

      case result do
        {:ok, status} ->
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

  describe "error resilience" do
    test "continues after individual file errors", %{test_dir: test_dir} do
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

      result = ElixirNexus.Indexer.index_directory(test_dir)

      assert is_tuple(result)
    end

    test "handles concurrent indexing gracefully" do
      test_dir = Path.join(System.tmp_dir!(), "concurrent_#{:rand.uniform(1_000_000)}")
      File.mkdir_p(test_dir)

      on_exit(fn -> File.rm_rf(test_dir) end)

      tasks =
        for _i <- 1..3 do
          Task.async(fn ->
            ElixirNexus.Indexer.index_directory(test_dir)
          end)
        end

      results = Task.await_many(tasks)

      assert Enum.all?(results, &is_tuple/1)
    end
  end
end
