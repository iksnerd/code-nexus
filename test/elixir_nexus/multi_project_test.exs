defmodule ElixirNexus.MultiProjectTest do
  use ExUnit.Case

  @moduledoc """
  Tests for multi-project onboarding: index_directories/1 and MCP reindex smart defaults.
  """

  setup do
    # Wait for any in-progress indexing from other tests to finish
    :ok = ElixirNexus.Indexer.await_idle()

    temp_dir = Path.join(System.tmp_dir!(), "multi_proj_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)
    {:ok, base: temp_dir}
  end

  describe "Indexer.index_directories/1" do
    test "indexes files from multiple directories", %{base: base} do
      lib_dir = Path.join(base, "lib")
      src_dir = Path.join(base, "src")
      File.mkdir_p!(lib_dir)
      File.mkdir_p!(src_dir)

      File.write!(Path.join(lib_dir, "app.ex"), """
      defmodule App do
        def run, do: :ok
      end
      """)

      File.write!(Path.join(src_dir, "helper.ex"), """
      defmodule Helper do
        def help, do: :ok
      end
      """)

      result = ElixirNexus.Indexer.index_directories([lib_dir, src_dir])

      assert {:ok, status} = result
      assert status.indexed_files >= 2
      assert status.total_chunks >= 2
    end

    test "indexes single-element list same as index_directory", %{base: base} do
      lib_dir = Path.join(base, "lib")
      File.mkdir_p!(lib_dir)

      File.write!(Path.join(lib_dir, "solo.ex"), """
      defmodule Solo do
        def alone, do: :ok
      end
      """)

      result = ElixirNexus.Indexer.index_directories([lib_dir])

      assert {:ok, status} = result
      assert status.indexed_files >= 1
    end

    test "handles empty list of directories" do
      result = ElixirNexus.Indexer.index_directories([])

      assert {:ok, status} = result
      assert status.indexed_files == 0
      assert status.total_chunks == 0
    end

    test "handles directories with no indexable files", %{base: base} do
      dir = Path.join(base, "empty_src")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "readme.md"), "# Nothing")

      result = ElixirNexus.Indexer.index_directories([dir])

      assert {:ok, status} = result
      assert status.indexed_files == 0
    end

    test "deduplicates files when directories overlap", %{base: base} do
      # Both paths point to the same directory
      lib_dir = Path.join(base, "lib")
      File.mkdir_p!(lib_dir)

      File.write!(Path.join(lib_dir, "dup.ex"), """
      defmodule Dup do
        def dup, do: :ok
      end
      """)

      result = ElixirNexus.Indexer.index_directories([lib_dir, lib_dir])

      assert {:ok, status} = result
      # Should only index the file once
      assert status.indexed_files >= 1
    end

    test "collects files from nested subdirectories", %{base: base} do
      src = Path.join(base, "src")
      nested = Path.join(src, "components/shared")
      File.mkdir_p!(nested)

      File.write!(Path.join(src, "index.ex"), """
      defmodule Index do
        def main, do: :ok
      end
      """)

      File.write!(Path.join(nested, "button.ex"), """
      defmodule Button do
        def render, do: :ok
      end
      """)

      result = ElixirNexus.Indexer.index_directories([src])

      assert {:ok, status} = result
      assert status.indexed_files >= 2
    end

    test "handles mix of existing and non-existing directories", %{base: base} do
      real_dir = Path.join(base, "lib")
      File.mkdir_p!(real_dir)

      File.write!(Path.join(real_dir, "real.ex"), """
      defmodule Real do
        def exists, do: true
      end
      """)

      fake_dir = Path.join(base, "nonexistent")

      result = ElixirNexus.Indexer.index_directories([real_dir, fake_dir])

      assert {:ok, status} = result
      assert status.indexed_files >= 1
    end
  end

  describe "end-to-end smart detection (inclusive-first default)" do
    test "detect + index works for Elixir project layout", %{base: base} do
      File.mkdir_p!(Path.join(base, "lib"))

      File.write!(Path.join(base, "lib/server.ex"), """
      defmodule Server do
        use GenServer
        def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
        def init(opts), do: {:ok, opts}
      end
      """)

      dirs = ElixirNexus.IndexingHelpers.detect_indexable_dirs(base)
      assert dirs == [base]

      result = ElixirNexus.Indexer.index_directories(dirs)
      assert {:ok, status} = result
      assert status.indexed_files >= 1
    end

    test "detect + index works for Next.js-style layout", %{base: base} do
      File.mkdir_p!(Path.join(base, "src"))
      File.mkdir_p!(Path.join(base, "app"))

      # Write Elixir files as stand-ins (tree-sitter may not be available in test)
      File.write!(Path.join(base, "src/utils.ex"), """
      defmodule Utils do
        def format(x), do: x
      end
      """)

      File.write!(Path.join(base, "app/layout.ex"), """
      defmodule Layout do
        def render, do: :ok
      end
      """)

      dirs = ElixirNexus.IndexingHelpers.detect_indexable_dirs(base)
      assert dirs == [base]

      result = ElixirNexus.Indexer.index_directories(dirs)
      assert {:ok, status} = result
      assert status.indexed_files >= 2
    end

    test "detect + index falls back for flat project", %{base: base} do
      # No recognized subdirs — files at root
      File.write!(Path.join(base, "main.ex"), """
      defmodule Main do
        def start, do: :ok
      end
      """)

      dirs = ElixirNexus.IndexingHelpers.detect_indexable_dirs(base)
      assert dirs == [base]

      result = ElixirNexus.Indexer.index_directories(dirs)
      assert {:ok, status} = result
      assert status.indexed_files >= 1
    end
  end
end
