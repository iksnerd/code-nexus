defmodule ElixirNexus.ApplicationTest do
  use ExUnit.Case, async: false

  describe "supervision tree" do
    test "CacheOwner is alive" do
      assert Process.whereis(ElixirNexus.CacheOwner) |> Process.alive?()
    end

    test "QdrantClient is alive" do
      assert Process.whereis(ElixirNexus.QdrantClient) |> Process.alive?()
    end

    test "Indexer is alive" do
      assert Process.whereis(ElixirNexus.Indexer) |> Process.alive?()
    end

    test "DirtyTracker is alive" do
      assert Process.whereis(ElixirNexus.DirtyTracker) |> Process.alive?()
    end

    test "FileWatcher is alive" do
      assert Process.whereis(ElixirNexus.FileWatcher) |> Process.alive?()
    end

    test "Registry is alive" do
      assert Process.whereis(ElixirNexus.Registry) |> Process.alive?()
    end

    test "TFIDFEmbedder is alive" do
      assert Process.whereis(ElixirNexus.TFIDFEmbedder) |> Process.alive?()
    end

    test "TaskSupervisor is alive" do
      assert Process.whereis(ElixirNexus.TaskSupervisor) |> Process.alive?()
    end
  end
end
