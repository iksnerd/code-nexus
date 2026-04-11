defmodule ElixirNexus.Search.ModuleHierarchy do
  @moduledoc "Find a module's parent behaviours and contained entities."

  require Logger

  alias ElixirNexus.Search.{DataFetching, EntityResolution}

  @doc """
  Find a module's hierarchy: parent behaviours/uses (is_a) and contained entities (contains).
  """
  def find_module_hierarchy(entity_name) do
    Logger.info("Finding module hierarchy for: #{entity_name}")

    case DataFetching.get_all_entities_cached(2000) do
      {:ok, all_entities} ->
        target = EntityResolution.find_entity_multi_strategy(entity_name, all_entities)

        case target do
          nil ->
            {:error, :not_found}

          target ->
            parent_names = target.entity["is_a"] || []
            child_names = target.entity["contains"] || []

            parents = EntityResolution.resolve_names(parent_names, all_entities)
            children = EntityResolution.resolve_names(child_names, all_entities)

            {:ok,
             %{
               name: target.entity["name"],
               entity_type: target.entity["entity_type"],
               file_path: target.entity["file_path"],
               parents: parents,
               children: children
             }}
        end

      error ->
        error
    end
  end
end
