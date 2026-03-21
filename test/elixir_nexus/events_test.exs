defmodule ElixirNexus.EventsTest do
  use ExUnit.Case, async: false

  alias ElixirNexus.Events

  setup do
    # Unsubscribe from both topics to prevent message leaking between tests
    Phoenix.PubSub.unsubscribe(ElixirNexus.PubSub, "indexing:events")
    Phoenix.PubSub.unsubscribe(ElixirNexus.PubSub, "collection:events")
    # Flush any leftover messages in the process mailbox
    flush_mailbox()
    :ok
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  describe "indexing events" do
    test "subscribe and receive indexing_progress" do
      Events.subscribe_indexing()
      Events.broadcast_indexing_progress(%{file: "test.ex", progress: 50})
      assert_receive {:indexing_progress, %{file: "test.ex", progress: 50}}
    end

    test "subscribe and receive indexing_complete" do
      Events.subscribe_indexing()
      Events.broadcast_indexing_complete(%{files: 10, chunks: 50})
      assert_receive {:indexing_complete, %{files: 10, chunks: 50}}
    end

    test "subscribe and receive file_reindexed" do
      Events.subscribe_indexing()
      Events.broadcast_file_reindexed("lib/my_module.ex")
      assert_receive {:file_reindexed, "lib/my_module.ex"}
    end

    test "unsubscribed process does not receive events" do
      # Don't subscribe, just broadcast
      Events.broadcast_indexing_complete(%{files: 1, chunks: 5})
      refute_receive {:indexing_complete, _}, 100
    end
  end

  describe "collection events" do
    test "subscribe and receive collection_changed" do
      Events.subscribe_collection()
      Events.broadcast_collection_changed("nexus_my_project")
      assert_receive {:collection_changed, "nexus_my_project"}
    end

    test "collection subscriber does not receive indexing events" do
      Events.subscribe_collection()
      Events.broadcast_indexing_complete(%{files: 5, chunks: 20})
      refute_receive {:indexing_complete, _}, 100
    end

    test "indexing subscriber does not receive collection events" do
      Events.subscribe_indexing()
      Events.broadcast_collection_changed("nexus_other")
      refute_receive {:collection_changed, _}, 100
    end
  end
end
