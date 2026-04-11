defmodule ElixirNexus.Search.Queries do
  @moduledoc """
  Public facade for code-graph queries.
  Each function delegates to a focused domain module.
  """

  defdelegate analyze_impact(entity_name, depth \\ 3),
    to: ElixirNexus.Search.ImpactAnalysis

  defdelegate find_callees(entity_name, limit \\ 20),
    to: ElixirNexus.Search.CalleeFinder

  defdelegate find_callers(entity_name, limit \\ 20),
    to: ElixirNexus.Search.CallerFinder

  defdelegate get_community_context(file_path, limit \\ 10),
    to: ElixirNexus.Search.CommunityContext

  defdelegate find_dead_code(opts \\ []),
    to: ElixirNexus.Search.DeadCodeDetection

  defdelegate get_graph_stats(),
    to: ElixirNexus.Search.GraphStats

  defdelegate find_module_hierarchy(entity_name),
    to: ElixirNexus.Search.ModuleHierarchy
end
