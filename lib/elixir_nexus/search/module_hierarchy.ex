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

            # For function/method entities, supplement children with PascalCase calls.
            # JSX component renders (<Button />, <FileExplorer />) land in :calls with
            # PascalCase names — they won't appear in :contains, which is only populated
            # for class/module-level entities by the extractors.
            children =
              if target.entity["entity_type"] in ["function", "method"] do
                jsx_names =
                  (target.entity["calls"] || [])
                  |> Enum.filter(&Regex.match?(~r/^[A-Z]/, &1))
                  |> Enum.uniq()

                jsx_children =
                  EntityResolution.resolve_names(jsx_names, all_entities)
                  |> Enum.filter(& &1.resolved)

                (children ++ jsx_children)
                |> Enum.uniq_by(&{&1[:name], &1[:file_path]})
              else
                children
              end

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
