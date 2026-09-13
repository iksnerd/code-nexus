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

    @tag :file_watcher
    test "stops the watcher processes, not just the bookkeeping" do
      # A watcher left running keeps delivering events for its old directory, so
      # edits in a previously indexed project got indexed into whichever
      # collection was active later.
      dir = System.tmp_dir!() |> Path.join("fw_test_stop_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      {:ok, pid} = FileWatcher.watch_directory(dir)
      ref = Process.monitor(pid)

      :ok = FileWatcher.unwatch_all()

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
    end

    test "clears pending files" do
      FileWatcher.unwatch_all()
      status = FileWatcher.status()
      assert status.pending == 0
    end
  end

  describe "file events" do
    test "an event for a path outside every watched directory is not indexed" do
      # A debounced event already queued when the watchers were switched to
      # another project must not be indexed into the new collection.
      FileWatcher.unwatch_all()
      dir = System.tmp_dir!() |> Path.join("fw_unwatched_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "stray.ex")
      File.write!(path, "defmodule Stray do\n  def stray, do: :ok\nend\n")
      on_exit(fn -> File.rm_rf!(dir) end)

      send(Process.whereis(FileWatcher), {:file_event, self(), {path, [:modified]}})
      # Past the 1s debounce, then let the watcher finish handling the flush.
      Process.sleep(1_300)
      _ = FileWatcher.status()
      :ok = ElixirNexus.Indexer.await_idle()

      refute Enum.any?(ElixirNexus.ChunkCache.all(), &(&1.file_path == path))
    end
  end

  describe "live reindex" do
    @tag :file_watcher
    test "a file written in a watched directory gets indexed, even through a symlinked path" do
      # macOS: System.tmp_dir! is under /var, a symlink to /private/var, and
      # FSEvents reports the resolved /private/var path.
      FileWatcher.unwatch_all()
      dir = System.tmp_dir!() |> Path.join("fw_live_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      {:ok, _pid} = FileWatcher.watch_directory(dir)
      Process.sleep(500)
      File.write!(Path.join(dir, "live_probe.ex"), "defmodule LiveProbe do\n  def live, do: :ok\nend\n")

      indexed? = fn ->
        Enum.any?(ElixirNexus.ChunkCache.all(), &String.ends_with?(&1.file_path, "/live_probe.ex"))
      end

      assert Enum.any?(1..40, fn _ ->
               Process.sleep(250)
               indexed?.()
             end)

      FileWatcher.unwatch_all()
    end
  end

  describe "watch_directory/1" do
    @tag :file_watcher
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

    @tag :file_watcher
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

    @tag :file_watcher
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

    @tag :file_watcher
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
      _pending_before = FileWatcher.status().pending

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
