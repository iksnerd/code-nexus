defmodule ElixirNexus.IndexerBehaviour do
  @moduledoc "Behaviour for Indexer operations."

  @callback index_directories(list(String.t())) :: {:ok, map()} | {:error, any()}
  @callback index_file(String.t()) :: {:ok, list()} | {:error, any()}
  @callback status() :: map()
end
