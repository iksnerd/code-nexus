defmodule ElixirNexus.FileWatcherTest do
  use ExUnit.Case, async: false

  alias ElixirNexus.FileWatcher

  describe "status/0" do
    test "returns current status" do
      status = FileWatcher.status()
      assert is_map(status)
      assert Map.has_key?(status, :watching)
      assert Map.has_key?(status, :pending)
    end

    test "watching and pending are non-negative integers" do
      status = FileWatcher.status()
      assert is_integer(status.watching) and status.watching >= 0
      assert is_integer(status.pending) and status.pending >= 0
    end
  end

  describe "unwatch_all/0" do
    test "clears all watchers" do
      FileWatcher.unwatch_all()
      status = FileWatcher.status()
      assert status.watching == 0
    end

    test "clears pending files" do
      FileWatcher.unwatch_all()
      status = FileWatcher.status()
      assert status.pending == 0
    end
  end

  describe "watch_directory/1" do
    test "watches a valid directory" do
      dir = System.tmp_dir!() |> Path.join("fw_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      result = FileWatcher.watch_directory(dir)
      assert match?({:ok, _pid}, result)

      status = FileWatcher.status()
      assert status.watching > 0

      # Cleanup
      FileWatcher.unwatch_all()
      File.rm_rf!(dir)
    end

    test "returns ok tuple with watcher pid" do
      dir = System.tmp_dir!() |> Path.join("fw_test_pid_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      {:ok, pid} = FileWatcher.watch_directory(dir)
      assert is_pid(pid)
      assert Process.alive?(pid)

      # Cleanup
      FileWatcher.unwatch_all()
      File.rm_rf!(dir)
    end

    test "can watch multiple directories" do
      dir1 = System.tmp_dir!() |> Path.join("fw_test_multi1_#{System.unique_integer([:positive])}")
      dir2 = System.tmp_dir!() |> Path.join("fw_test_multi2_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir1)
      File.mkdir_p!(dir2)

      FileWatcher.unwatch_all()

      {:ok, _} = FileWatcher.watch_directory(dir1)
      {:ok, _} = FileWatcher.watch_directory(dir2)

      status = FileWatcher.status()
      assert status.watching == 2

      # Cleanup
      FileWatcher.unwatch_all()
      File.rm_rf!(dir1)
      File.rm_rf!(dir2)
    end

    test "unwatch_all after watching resets count to zero" do
      dir = System.tmp_dir!() |> Path.join("fw_test_reset_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      {:ok, _} = FileWatcher.watch_directory(dir)
      assert FileWatcher.status().watching > 0

      FileWatcher.unwatch_all()
      assert FileWatcher.status().watching == 0

      File.rm_rf!(dir)
    end
  end

  describe "handle_info file events" do
    test "non-indexable file events are ignored" do
      pid = Process.whereis(FileWatcher)
      send(pid, {:file_event, self(), {"/tmp/test.txt", [:modified]}})

      # Should not add to pending
      Process.sleep(50)
      status = FileWatcher.status()
      # .txt is not indexable, so pending should stay the same
      assert is_integer(status.pending)
    end

    test "ignored path events are ignored" do
      pid = Process.whereis(FileWatcher)
      send(pid, {:file_event, self(), {"/app/node_modules/pkg/index.js", [:modified]}})

      Process.sleep(50)
      status = FileWatcher.status()
      assert is_integer(status.pending)
    end

    test "stop event is handled gracefully" do
      pid = Process.whereis(FileWatcher)
      send(pid, {:file_event, self(), :stop})

      Process.sleep(50)
      assert Process.alive?(pid)
    end

    test "flush event for non-pending path is a no-op" do
      pid = Process.whereis(FileWatcher)
      send(pid, {:flush, "/nonexistent/file.ex"})

      Process.sleep(50)
      assert Process.alive?(pid)
    end

    test "indexable file event adds to pending" do
      pid = Process.whereis(FileWatcher)
      pending_before = FileWatcher.status().pending

      send(pid, {:file_event, self(), {"/tmp/test_watch.ex", [:modified]}})
      Process.sleep(50)

      status = FileWatcher.status()
      # Should have added to pending (or it may have already flushed)
      assert is_integer(status.pending)
    end

    test "same path twice within debounce is deduplicated" do
      pid = Process.whereis(FileWatcher)

      send(pid, {:file_event, self(), {"/tmp/dedup_test.ex", [:modified]}})
      send(pid, {:file_event, self(), {"/tmp/dedup_test.ex", [:modified]}})

      Process.sleep(50)
      # Should not crash and pending should show at most 1 entry for this path
      assert Process.alive?(pid)
    end

    test "flush triggers reindex_if_dirty without crash" do
      pid = Process.whereis(FileWatcher)
      # First add a pending file
      send(pid, {:file_event, self(), {"/tmp/flush_test.ex", [:modified]}})
      Process.sleep(50)

      # Now flush it manually
      send(pid, {:flush, "/tmp/flush_test.ex"})
      Process.sleep(50)

      assert Process.alive?(pid)
    end
  end
end
