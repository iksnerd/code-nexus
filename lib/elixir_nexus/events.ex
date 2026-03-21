defmodule ElixirNexus.Events do
  @moduledoc "PubSub broadcast/subscribe helpers for indexing events."
  require Logger

  @topic "indexing:events"
  @collection_topic "collection:events"

  def subscribe_indexing do
    Logger.info("Events: process #{inspect(self())} subscribed to #{@topic}")
    Phoenix.PubSub.subscribe(ElixirNexus.PubSub, @topic)
  end

  def broadcast_indexing_progress(data) do
    Phoenix.PubSub.broadcast(ElixirNexus.PubSub, @topic, {:indexing_progress, data})
  end

  def broadcast_indexing_complete(data) do
    Logger.info("Events: broadcasting :indexing_complete on topic #{@topic}")
    result = Phoenix.PubSub.broadcast(ElixirNexus.PubSub, @topic, {:indexing_complete, data})
    Logger.info("Events: broadcast result: #{inspect(result)}")
    result
  end

  def broadcast_file_reindexed(file_path) do
    Phoenix.PubSub.broadcast(ElixirNexus.PubSub, @topic, {:file_reindexed, file_path})
  end

  def subscribe_collection do
    Phoenix.PubSub.subscribe(ElixirNexus.PubSub, @collection_topic)
  end

  def broadcast_collection_changed(collection_name) do
    Phoenix.PubSub.broadcast(ElixirNexus.PubSub, @collection_topic, {:collection_changed, collection_name})
  end
end
