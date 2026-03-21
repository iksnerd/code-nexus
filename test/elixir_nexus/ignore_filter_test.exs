defmodule ElixirNexus.IgnoreFilterTest do
  use ExUnit.Case, async: true

  alias ElixirNexus.IgnoreFilter

  @test_dir "/tmp/ignore_filter_test_#{System.unique_integer([:positive])}"

  setup do
    File.mkdir_p!(@test_dir)

    on_exit(fn ->
      File.rm_rf!(@test_dir)
    end)

    :ok
  end

  describe "load/1" do
    test "includes default ignores" do
      filter = IgnoreFilter.load(@test_dir)
      assert IgnoreFilter.ignored_dir?("node_modules", filter)
      assert IgnoreFilter.ignored_dir?("_build", filter)
      assert IgnoreFilter.ignored_dir?("deps", filter)
      assert IgnoreFilter.ignored_dir?(".git", filter)
    end

    test "loads patterns from .gitignore" do
      File.write!(Path.join(@test_dir, ".gitignore"), """
      build/
      dist
      # comment line
      .env
      """)

      filter = IgnoreFilter.load(@test_dir)
      assert IgnoreFilter.ignored_dir?("build", filter)
      assert IgnoreFilter.ignored_dir?("dist", filter)
    end

    test "ignores glob patterns in .gitignore" do
      File.write!(Path.join(@test_dir, ".gitignore"), """
      *.log
      build/
      temp?/
      """)

      filter = IgnoreFilter.load(@test_dir)
      # Glob patterns are skipped — only simple dir names
      assert IgnoreFilter.ignored_dir?("build", filter)
      # *.log and temp? are glob patterns, should not be added
    end

    test "ignores negation patterns" do
      File.write!(Path.join(@test_dir, ".gitignore"), """
      !important/
      build/
      """)

      filter = IgnoreFilter.load(@test_dir)
      assert IgnoreFilter.ignored_dir?("build", filter)
    end

    test "works without .gitignore" do
      filter = IgnoreFilter.load(@test_dir)
      # Should still have defaults
      assert IgnoreFilter.ignored_dir?("node_modules", filter)
    end
  end

  describe "ignored_dir?/2" do
    test "matches directory names" do
      filter = IgnoreFilter.load(@test_dir)
      assert IgnoreFilter.ignored_dir?("node_modules", filter)
      refute IgnoreFilter.ignored_dir?("lib", filter)
      refute IgnoreFilter.ignored_dir?("src", filter)
    end

    test "rejects dotfiles/dotdirs" do
      filter = IgnoreFilter.load(@test_dir)
      assert IgnoreFilter.ignored_dir?(".hidden", filter)
      assert IgnoreFilter.ignored_dir?(".cache", filter)
    end
  end

  describe "ignored?/2" do
    test "checks basename against ignore set" do
      filter = IgnoreFilter.load(@test_dir)
      assert IgnoreFilter.ignored?("node_modules", filter)
      assert IgnoreFilter.ignored?("/some/path/node_modules", filter)
      refute IgnoreFilter.ignored?("my_module.ex", filter)
    end

    test "rejects dotfiles" do
      filter = IgnoreFilter.load(@test_dir)
      assert IgnoreFilter.ignored?(".env", filter)
      assert IgnoreFilter.ignored?("/path/to/.secret", filter)
    end
  end
end
