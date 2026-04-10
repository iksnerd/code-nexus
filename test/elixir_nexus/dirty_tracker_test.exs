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

  describe "dirty?/1" do
    test "first-seen file is always dirty" do
      path = Path.join(@test_dir, "new_file.ex")
      File.write!(path, "defmodule Foo do\nend\n")

      assert {true, _checksum} = DirtyTracker.dirty?(path)
    end

    test "file is still dirty if not marked clean" do
      path = Path.join(@test_dir, "unmarked.ex")
      File.write!(path, "defmodule Bar do\nend\n")

      assert {true, _} = DirtyTracker.dirty?(path)
      # Checking again without marking clean — still dirty (no stored checksum)
      assert {true, _} = DirtyTracker.dirty?(path)
    end

    test "returns error for nonexistent file" do
      assert {:error, :enoent} = DirtyTracker.dirty?("/tmp/nonexistent_#{System.unique_integer()}.ex")
    end
  end

  describe "mark_clean/1" do
    test "file is clean after mark_clean" do
      path = Path.join(@test_dir, "clean.ex")
      File.write!(path, "defmodule Clean do\nend\n")

      assert {true, _} = DirtyTracker.dirty?(path)
      assert {:ok, _checksum} = DirtyTracker.mark_clean(path)
      assert {false, _} = DirtyTracker.dirty?(path)
    end

    test "modified file becomes dirty again" do
      path = Path.join(@test_dir, "modified.ex")
      File.write!(path, "defmodule V1 do\nend\n")

      DirtyTracker.mark_clean(path)
      assert {false, _} = DirtyTracker.dirty?(path)

      # Modify the file
      File.write!(path, "defmodule V2 do\nend\n")
      assert {true, _} = DirtyTracker.dirty?(path)
    end
  end

  describe "reset/0" do
    test "reset makes all files dirty again" do
      path = Path.join(@test_dir, "reset_test.ex")
      File.write!(path, "defmodule Reset do\nend\n")

      DirtyTracker.mark_clean(path)
      assert {false, _} = DirtyTracker.dirty?(path)

      assert :ok = DirtyTracker.reset()
      assert {true, _} = DirtyTracker.dirty?(path)
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

  describe "forget/1" do
    test "forget removes a file's checksum" do
      path = Path.join(@test_dir, "forget_me.ex")
      File.write!(path, "defmodule ForgetMe do\nend\n")

      # Mark clean first
      DirtyTracker.mark_clean(path)
      assert {false, _} = DirtyTracker.dirty?(path)

      # Forget the file — should make it dirty again (no stored checksum)
      assert :ok = DirtyTracker.forget(path)
      assert {true, _} = DirtyTracker.dirty?(path)
    end

    test "forget on unknown file is a no-op" do
      # Should not crash when forgetting a file we never tracked
      assert :ok = DirtyTracker.forget("/tmp/never_tracked_#{System.unique_integer()}.ex")
    end
  end

  describe "get_dirty_files_recursive/1" do
    test "finds dirty files in nested directories" do
      sub_dir = Path.join(@test_dir, "nested/deep")
      File.mkdir_p!(sub_dir)

      File.write!(Path.join(@test_dir, "top.ts"), "export const top = 1;")
      File.write!(Path.join(sub_dir, "deep.ts"), "export const deep = 2;")
      File.write!(Path.join(sub_dir, "readme.txt"), "not indexable")

      assert {:ok, dirty} = DirtyTracker.get_dirty_files_recursive([@test_dir])

      dirty_basenames = Enum.map(dirty, &Path.basename/1)
      assert "top.ts" in dirty_basenames
      assert "deep.ts" in dirty_basenames
      refute "readme.txt" in dirty_basenames
    end

    test "excludes clean files from recursive scan" do
      sub_dir = Path.join(@test_dir, "src")
      File.mkdir_p!(sub_dir)

      clean_path = Path.join(sub_dir, "clean.ex")
      dirty_path = Path.join(sub_dir, "dirty.ex")

      File.write!(clean_path, "defmodule Clean do\nend\n")
      File.write!(dirty_path, "defmodule Dirty do\nend\n")

      DirtyTracker.mark_clean(clean_path)

      assert {:ok, dirty} = DirtyTracker.get_dirty_files_recursive([@test_dir])

      dirty_basenames = Enum.map(dirty, &Path.basename/1)
      assert "dirty.ex" in dirty_basenames
      refute "clean.ex" in dirty_basenames
    end

    test "skips ignored directories like node_modules" do
      ignored_dir = Path.join(@test_dir, "node_modules")
      File.mkdir_p!(ignored_dir)
      File.write!(Path.join(ignored_dir, "lib.js"), "module.exports = {};")

      assert {:ok, dirty} = DirtyTracker.get_dirty_files_recursive([@test_dir])
      refute Enum.any?(dirty, &String.contains?(&1, "node_modules"))
    end

    test "returns empty list when all files are clean" do
      path = Path.join(@test_dir, "all_clean.ex")
      File.write!(path, "defmodule AllClean do\nend\n")
      DirtyTracker.mark_clean(path)

      assert {:ok, []} = DirtyTracker.get_dirty_files_recursive([@test_dir])
    end

    test "detects file modified after mark_clean" do
      path = Path.join(@test_dir, "will_change.ts")
      File.write!(path, "export const v1 = 1;")
      DirtyTracker.mark_clean(path)

      assert {:ok, []} = DirtyTracker.get_dirty_files_recursive([@test_dir])

      File.write!(path, "export const v2 = 2;")

      assert {:ok, dirty} = DirtyTracker.get_dirty_files_recursive([@test_dir])
      assert Path.basename(hd(dirty)) == "will_change.ts"
    end
  end
end
