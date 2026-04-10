defmodule ElixirNexus.QdrantBehaviour do
  @moduledoc "Behaviour for Qdrant client operations."

  @callback health_check() :: {:ok, any()} | {:error, any()}
  @callback search(list(), integer()) :: {:ok, map()} | {:error, any()}
  @callback hybrid_search(list(), map(), integer()) :: {:ok, map()} | {:error, any()}
  @callback upsert_points(list()) :: {:ok, map()} | {:error, any()}
  @callback collection_info() :: {:ok, map()} | {:error, any()}
  @callback scroll_points(integer(), any(), any()) :: {:ok, map()} | {:error, any()}
  @callback count_points(map() | nil) :: {:ok, map()} | {:error, any()}
  @callback get_point(any()) :: {:ok, map()} | {:error, any()}
  @callback delete_points(list()) :: {:ok, map()} | {:error, any()}
  @callback list_collections() :: {:ok, list()} | {:error, any()}
  @callback active_collection() :: String.t()
  @callback delete_collection() :: {:ok, map()} | {:error, any()}
  @callback delete_collection(String.t()) :: {:ok, map()} | {:error, any()}
  @callback reset_collection() :: {:ok, map()} | {:error, any()}
  @callback switch_collection(String.t()) :: :ok | {:error, any()}
end
