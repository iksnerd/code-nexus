defmodule ElixirNexus.SearchBehaviour do
  @moduledoc "Behaviour for Search operations."

  @callback search_code(String.t(), integer()) :: {:ok, list()} | {:error, any()}
  @callback find_callees(String.t(), integer()) :: {:ok, list()} | {:error, any()}
  @callback analyze_impact(String.t(), integer()) :: {:ok, map()} | {:error, any()}
  @callback get_community_context(String.t(), integer()) :: {:ok, map()} | {:error, any()}
  @callback get_graph_stats() :: {:ok, map()} | {:error, any()}
  @callback find_module_hierarchy(String.t()) :: {:ok, map()} | {:error, any()}
end
