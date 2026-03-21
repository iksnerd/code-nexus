defmodule ElixirNexus.DirtyTrackerTest do
  use ExUnit.Case, async: false

  alias ElixirNexus.DirtyTracker

  @test_dir "/tmp/dirty_tracker_test_#{System.unique_integer([:positive])}"

  setup do
    File.mkdir_p!(@test_dir)

    # Use the already-running supervised instance — just reset state
    DirtyTracker.reset()

    on_exit(fn ->
      File.rm_rf!(@test_dir)
    end)

    :ok
  end

  describe "is_dirty?/1" do
    test "first-seen file is always dirty" do
      path = Path.join(@test_dir, "new_file.ex")
      File.write!(path, "defmodule Foo do\nend\n")

      assert {true, _checksum} = DirtyTracker.is_dirty?(path)
    end

    test "file is still dirty if not marked clean" do
      path = Path.join(@test_dir, "unmarked.ex")
      File.write!(path, "defmodule Bar do\nend\n")

      assert {true, _} = DirtyTracker.is_dirty?(path)
      # Checking again without marking clean — still dirty (no stored checksum)
      assert {true, _} = DirtyTracker.is_dirty?(path)
    end

    test "returns error for nonexistent file" do
      assert {:error, :enoent} = DirtyTracker.is_dirty?("/tmp/nonexistent_#{System.unique_integer()}.ex")
    end
  end

  describe "mark_clean/1" do
    test "file is clean after mark_clean" do
      path = Path.join(@test_dir, "clean.ex")
      File.write!(path, "defmodule Clean do\nend\n")

      assert {true, _} = DirtyTracker.is_dirty?(path)
      assert {:ok, _checksum} = DirtyTracker.mark_clean(path)
      assert {false, _} = DirtyTracker.is_dirty?(path)
    end

    test "modified file becomes dirty again" do
      path = Path.join(@test_dir, "modified.ex")
      File.write!(path, "defmodule V1 do\nend\n")

      DirtyTracker.mark_clean(path)
      assert {false, _} = DirtyTracker.is_dirty?(path)

      # Modify the file
      File.write!(path, "defmodule V2 do\nend\n")
      assert {true, _} = DirtyTracker.is_dirty?(path)
    end
  end

  describe "reset/0" do
    test "reset makes all files dirty again" do
      path = Path.join(@test_dir, "reset_test.ex")
      File.write!(path, "defmodule Reset do\nend\n")

      DirtyTracker.mark_clean(path)
      assert {false, _} = DirtyTracker.is_dirty?(path)

      assert :ok = DirtyTracker.reset()
      assert {true, _} = DirtyTracker.is_dirty?(path)
    end
  end

  describe "get_dirty_files/1" do
    test "returns dirty .ex/.exs files in directory" do
      # Create some files
      File.write!(Path.join(@test_dir, "a.ex"), "defmodule A do\nend\n")
      File.write!(Path.join(@test_dir, "b.exs"), "defmodule B do\nend\n")
      File.write!(Path.join(@test_dir, "c.txt"), "not elixir")

      assert {:ok, dirty} = DirtyTracker.get_dirty_files(@test_dir)

      # Should include .ex and .exs files but not .txt
      dirty_basenames = Enum.map(dirty, &Path.basename/1)
      assert "a.ex" in dirty_basenames
      assert "b.exs" in dirty_basenames
      refute "c.txt" in dirty_basenames
    end

    test "clean files are excluded from dirty list" do
      File.write!(Path.join(@test_dir, "clean.ex"), "defmodule Clean do\nend\n")
      File.write!(Path.join(@test_dir, "dirty.ex"), "defmodule Dirty do\nend\n")

      DirtyTracker.mark_clean(Path.join(@test_dir, "clean.ex"))

      assert {:ok, dirty} = DirtyTracker.get_dirty_files(@test_dir)
      dirty_basenames = Enum.map(dirty, &Path.basename/1)

      assert "dirty.ex" in dirty_basenames
      refute "clean.ex" in dirty_basenames
    end

    test "returns error for nonexistent directory" do
      assert {:error, :enoent} = DirtyTracker.get_dirty_files("/tmp/nonexistent_dir_#{System.unique_integer()}")
    end
  end
end
