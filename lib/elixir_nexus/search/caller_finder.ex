defmodule ElixirNexus.Search.CallerFinder do
  @moduledoc "Find entities that call a given function, with enclosing-function refinement."

  alias ElixirNexus.Search.DataFetching

  @doc """
  Find all entities that call a specific function.
  Inverse of find_callees — walks call edges inbound.
  """
  def find_callers(entity_name, limit \\ 20) do
    call_callers = ElixirNexus.GraphCache.find_callers(entity_name)
    import_callers = ElixirNexus.GraphCache.find_importers(entity_name)

    # Merge and deduplicate by id, preferring call callers
    all_callers =
      (call_callers ++ import_callers)
      |> Enum.uniq_by(fn {id, _node} -> id end)

    results =
      all_callers
      |> Enum.take(limit)
      |> Enum.map(fn {id, node} ->
        %{
          id: id,
          score: 0.0,
          entity: %{
            "name" => node["name"],
            "file_path" => node["file_path"],
            "entity_type" => node["entity_type"] || node["type"],
            "start_line" => node["start_line"] || 0,
            "end_line" => node["end_line"] || 0,
            "calls" => node["calls"] || [],
            "is_a" => node["is_a"] || [],
            "contains" => node["contains"] || []
          }
        }
      end)

    # Refine module-level callers to their enclosing function entity where possible,
    # then deduplicate — refinement can produce an ID already present in results.
    refined =
      case DataFetching.get_all_entities_cached(2000) do
        {:ok, all_entities} ->
          results
          |> refine_entities_to_functions(entity_name, all_entities)
          |> Enum.uniq_by(& &1.id)

        _ ->
          results
      end

    {:ok, refined}
  end

  @doc """
  Replace module-level callers with a tighter function-level entity in the same file
  that explicitly calls the target. Used by both find_callers and analyze_impact.
  """
  def refine_entities_to_functions(entities, target_name, all_entities) do
    function_index = build_function_index(all_entities)
    target_lower = String.downcase(target_name)

    Enum.map(entities, fn result ->
      entity_type = result.entity["entity_type"] || ""
      file = result.entity["file_path"]

      if entity_type not in ["function", "method"] and is_binary(file) do
        find_enclosing_function(target_lower, result, function_index, file) || result
      else
        result
      end
    end)
  end

  # Group function/method entities by file path for O(1) lookup per file.
  defp build_function_index(all_entities) do
    all_entities
    |> Enum.filter(fn e -> e.entity["entity_type"] in ["function", "method"] end)
    |> Enum.group_by(fn e -> e.entity["file_path"] end)
  end

  # Given a module-level caller result, find the tightest function in the same file
  # that also calls the target entity. If line range info is available, prefers the
  # function whose range is contained within the module's range.
  defp find_enclosing_function(target_lower, module_result, function_index, file) do
    mod_start = module_result.entity["start_line"] || 0
    mod_end = module_result.entity["end_line"] || 0
    functions = Map.get(function_index, file, [])

    # Functions in this file that also call the target
    matching =
      Enum.filter(functions, fn func ->
        Enum.any?(func.entity["calls"] || [], fn c ->
          c_lower = String.downcase(c)

          c_lower == target_lower or
            String.ends_with?(c_lower, "." <> target_lower) or
            String.ends_with?(target_lower, "." <> c_lower)
        end)
      end)

    case matching do
      [] ->
        nil

      candidates ->
        if mod_end > mod_start do
          # Prefer the tightest function contained within the module's line range
          contained =
            Enum.filter(candidates, fn func ->
              f_start = func.entity["start_line"] || 0
              f_end = func.entity["end_line"] || 0
              f_start >= mod_start and f_end <= mod_end
            end)

          (contained ++ candidates)
          |> List.first()
        else
          # No line range info — return any function in the file calling the target
          List.first(candidates)
        end
    end
  end
end
