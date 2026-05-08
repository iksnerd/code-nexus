defmodule ElixirNexus.IndexingHelpersTest do
  use ExUnit.Case

  alias ElixirNexus.IndexingHelpers

  setup do
    temp_dir = Path.join(System.tmp_dir!(), "helpers_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)
    {:ok, base: temp_dir}
  end

  describe "count_languages/1" do
    test "groups files by language and counts" do
      files = [
        "/x/a.ex",
        "/x/b.ex",
        "/x/c.exs",
        "/x/d.ts",
        "/x/e.tsx",
        "/x/f.go",
        "/x/g.rs",
        "/x/README.md"
      ]

      counts = IndexingHelpers.count_languages(files)

      assert %{lang: :elixir, file_count: 3} in counts
      assert %{lang: :typescript, file_count: 1} in counts
      assert %{lang: :tsx, file_count: 1} in counts
      assert %{lang: :go, file_count: 1} in counts
      assert %{lang: :rust, file_count: 1} in counts
      # Unknown extensions (`.md`) are excluded
      refute Enum.any?(counts, &match?(%{lang: :unknown}, &1))
    end

    test "returns empty list for empty input" do
      assert IndexingHelpers.count_languages([]) == []
    end

    test "sorts by descending file count" do
      files = ["/x/a.go", "/x/a.ex", "/x/b.ex", "/x/c.ex"]

      counts = IndexingHelpers.count_languages(files)

      assert [%{lang: :elixir, file_count: 3}, %{lang: :go, file_count: 1}] = counts
    end
  end

  describe "language_for_extension/1" do
    test "maps known Elixir extensions" do
      assert IndexingHelpers.language_for_extension(".ex") == :elixir
      assert IndexingHelpers.language_for_extension(".exs") == :elixir
    end

    test "maps polyglot extensions" do
      assert IndexingHelpers.language_for_extension(".ts") == :typescript
      assert IndexingHelpers.language_for_extension(".tsx") == :tsx
      assert IndexingHelpers.language_for_extension(".py") == :python
      assert IndexingHelpers.language_for_extension(".go") == :go
    end

    test "returns :unknown for unrecognized extensions" do
      assert IndexingHelpers.language_for_extension(".md") == :unknown
      assert IndexingHelpers.language_for_extension(".astro") == :unknown
      assert IndexingHelpers.language_for_extension("") == :unknown
    end
  end

  describe "detect_indexable_dirs/1 (default: inclusive-first)" do
    test "returns base path even when conventional source dirs exist", %{base: base} do
      File.mkdir_p!(Path.join(base, "lib"))
      File.mkdir_p!(Path.join(base, "src"))

      dirs = IndexingHelpers.detect_indexable_dirs(base)

      assert dirs == [base]
    end

    test "returns base path for repos with non-conventional source dirs", %{base: base} do
      # e.g. CodeEditorLand/Mountain uses Source/ — would be skipped by curated mode
      File.mkdir_p!(Path.join(base, "Source"))

      dirs = IndexingHelpers.detect_indexable_dirs(base)

      assert dirs == [base]
    end

    test "returns base path for empty directories", %{base: base} do
      dirs = IndexingHelpers.detect_indexable_dirs(base)

      assert dirs == [base]
    end
  end

  describe "detect_indexable_dirs/1 with NEXUS_INDEX_STRATEGY=curated" do
    setup do
      prev = System.get_env("NEXUS_INDEX_STRATEGY")
      System.put_env("NEXUS_INDEX_STRATEGY", "curated")

      on_exit(fn ->
        if prev,
          do: System.put_env("NEXUS_INDEX_STRATEGY", prev),
          else: System.delete_env("NEXUS_INDEX_STRATEGY")
      end)

      :ok
    end

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
