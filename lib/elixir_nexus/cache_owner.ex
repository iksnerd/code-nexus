defmodule ElixirNexus.CacheOwner do
  @moduledoc "GenServer that owns ETS tables for GraphCache, ChunkCache, and TF-IDF."
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(ElixirNexus.GraphCache.table_name(), [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.new(ElixirNexus.ChunkCache.table_name(), [
      :bag,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.new(:nexus_tfidf_idf, [
      :set,
      :public,
      :named_table,
      read_concurrency: true
    ])

    {:ok, %{}}
  end
end
