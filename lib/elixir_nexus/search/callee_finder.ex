defmodule ElixirNexus.Search.CalleeFinder do
  @moduledoc "Find the entities a given function calls (its callees)."

  require Logger

  alias ElixirNexus.Search.{DataFetching, EntityResolution}

  @doc """
  Find all entities that a specific function calls.
  """
  def find_callees(entity_name, limit \\ 20) do
    Logger.info("Finding callees of: #{entity_name}")

    case DataFetching.get_all_entities_cached(2000) do
      {:ok, [_ | _] = all_entities} ->
        # Try multi-strategy resolution first (exact, file-path, substring) —
        # same as find_module_hierarchy. Falls back to Qdrant exact match.
        entity =
          EntityResolution.find_entity_multi_strategy(entity_name, all_entities) ||
            case get_definition(entity_name) do
              {:ok, e} -> e
              _ -> nil
            end

        case entity do
          nil -> {:error, :not_found}
          e -> resolve_callees(e, all_entities, limit)
        end

      _ ->
        # Cache empty — fall back to Qdrant exact match only
        case get_definition(entity_name) do
          {:ok, entity} ->
            calls = entity.entity["calls"] || []
            {:ok, Enum.map(Enum.take(calls, limit), &%{name: &1, resolved: false})}

          error ->
            error
        end
    end
  end

  defp resolve_callees(entity, all_entities, limit) do
    calls = entity.entity["calls"] || []
    caller_file = entity.entity["file_path"]

    resolved =
      calls
      |> Enum.take(limit)
      |> Enum.map(&resolve_call(&1, all_entities, caller_file))

    {:ok, resolved}
  end

  defp get_definition(entity_name) do
    Logger.info("Looking up definition: #{entity_name}")

    # Use scroll with a filter to find by name (avoids needing a real vector)
    filter = %{
      "must" => [
        %{"key" => "name", "match" => %{"value" => entity_name}}
      ]
    }

    case ElixirNexus.QdrantClient.scroll_points(1, nil, filter) do
      {:ok, %{"result" => %{"points" => [result | _]}}} ->
        {:ok, %{id: result["id"], score: 0.0, entity: ElixirNexus.Search.format_payload(result["payload"])}}

      {:ok, _} ->
        # Fallback: try search with a dummy vector
        dummy_vector = List.duplicate(0.0, 768)

        case ElixirNexus.QdrantClient.search_with_filter(dummy_vector, filter, 1) do
          {:ok, %{"result" => [result | _]}} ->
            {:ok,
             %{id: result["id"], score: result["score"], entity: ElixirNexus.Search.format_payload(result["payload"])}}

          {:ok, _} ->
            {:error, :not_found}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Resolve a call name to an entity, trying multiple strategies
  defp resolve_call(call_name, all_entities, caller_file) do
    candidates =
      Enum.filter(all_entities, &EntityResolution.matches_entity_name?(&1.entity["name"] || "", call_name))

    # Also try stripped method name: "adapter.createConnector" → "createConnector"
    candidates =
      if candidates == [] do
        method_name = call_name |> String.split(".") |> List.last()

        if method_name != call_name do
          Enum.filter(all_entities, &EntityResolution.matches_entity_name?(&1.entity["name"] || "", method_name))
        else
          []
        end
      else
        candidates
      end

    case candidates do
      [] ->
        %{name: call_name, resolved: false}

      [single] ->
        single

      multiple ->
        # Prefer same-file match to avoid cross-file false positives
        same_file = Enum.find(multiple, fn e -> e.entity["file_path"] == caller_file end)
        same_file || List.first(multiple)
    end
  end
end
