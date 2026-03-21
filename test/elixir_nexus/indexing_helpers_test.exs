defmodule ElixirNexus.IndexingHelpersTest do
  use ExUnit.Case

  alias ElixirNexus.IndexingHelpers

  setup do
    temp_dir = Path.join(System.tmp_dir!(), "helpers_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)
    {:ok, base: temp_dir}
  end

  describe "detect_indexable_dirs/1" do
    test "detects lib/ for Elixir projects", %{base: base} do
      File.mkdir_p!(Path.join(base, "lib"))

      dirs = IndexingHelpers.detect_indexable_dirs(base)

      assert dirs == [Path.join(base, "lib")]
    end

    test "detects src/ for JS/TS/Go/Rust projects", %{base: base} do
      File.mkdir_p!(Path.join(base, "src"))

      dirs = IndexingHelpers.detect_indexable_dirs(base)

      assert dirs == [Path.join(base, "src")]
    end

    test "detects multiple directories for Next.js projects", %{base: base} do
      File.mkdir_p!(Path.join(base, "src"))
      File.mkdir_p!(Path.join(base, "app"))
      File.mkdir_p!(Path.join(base, "pages"))
      File.mkdir_p!(Path.join(base, "components"))

      dirs = IndexingHelpers.detect_indexable_dirs(base)

      assert Path.join(base, "src") in dirs
      assert Path.join(base, "app") in dirs
      assert Path.join(base, "pages") in dirs
      assert Path.join(base, "components") in dirs
      assert length(dirs) == 4
    end

    test "detects both lib/ and src/ for mixed projects", %{base: base} do
      File.mkdir_p!(Path.join(base, "lib"))
      File.mkdir_p!(Path.join(base, "src"))

      dirs = IndexingHelpers.detect_indexable_dirs(base)

      assert Path.join(base, "lib") in dirs
      assert Path.join(base, "src") in dirs
      assert length(dirs) == 2
    end

    test "detects packages/ for monorepos", %{base: base} do
      File.mkdir_p!(Path.join(base, "packages"))

      dirs = IndexingHelpers.detect_indexable_dirs(base)

      assert dirs == [Path.join(base, "packages")]
    end

    test "falls back to base path when no recognized dirs exist", %{base: base} do
      # Empty directory — no lib/, src/, etc.
      dirs = IndexingHelpers.detect_indexable_dirs(base)

      assert dirs == [base]
    end

    test "ignores non-directory files with candidate names", %{base: base} do
      # Create a *file* named "lib" (not a directory)
      File.write!(Path.join(base, "lib"), "not a dir")

      dirs = IndexingHelpers.detect_indexable_dirs(base)

      assert dirs == [base]
    end

    test "preserves candidate order", %{base: base} do
      # Create in reverse order to ensure result follows candidate order, not filesystem order
      File.mkdir_p!(Path.join(base, "utils"))
      File.mkdir_p!(Path.join(base, "lib"))
      File.mkdir_p!(Path.join(base, "src"))

      dirs = IndexingHelpers.detect_indexable_dirs(base)

      lib_idx = Enum.find_index(dirs, &String.ends_with?(&1, "/lib"))
      src_idx = Enum.find_index(dirs, &String.ends_with?(&1, "/src"))
      utils_idx = Enum.find_index(dirs, &String.ends_with?(&1, "/utils"))

      assert lib_idx < src_idx
      assert src_idx < utils_idx
    end
  end
end
