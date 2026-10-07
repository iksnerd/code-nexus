defmodule ElixirNexus.Search.CallerFinder do
  @moduledoc "Find entities that call a given function, with enclosing-function refinement."

  alias ElixirNexus.Search.{DataFetching, ElixirCallIndex}

  @doc """
  Find all entities that call a specific function.
  Inverse of find_callees — walks call edges inbound.

  When the name matches Elixir definitions indexed with call-graph data, the
  answer is exact (`Mod.fun/arity`); callers that only a short-name match could
  reach (a call on a variable module) are listed after them with `"match" => "fallback"`.
  """
  def find_callers(entity_name, limit \\ 20) do
    case elixir_callers(entity_name, limit) do
      {:ok, results} -> {:ok, results}
      :not_elixir -> find_callers_by_name(entity_name, limit)
    end
  end

  defp elixir_callers(entity_name, limit) do
    with {:ok, all_entities} <- DataFetching.get_all_entities_cached(:all),
         true <- Enum.any?(all_entities, &ElixirCallIndex.xref?/1),
         index = ElixirCallIndex.build(all_entities),
         [_ | _] = targets <- ElixirCallIndex.targets(index, entity_name) do
      {:ok, index |> elixir_caller_edges(targets) |> Enum.take(limit) |> Enum.map(&elixir_caller_result/1)}
    else
      _ -> :not_elixir
    end
  end

  @doc false
  # `[{edge, target_qn, match}]`, exact first, one per caller function and target.
  def elixir_caller_edges(index, targets) do
    exact = for qn <- targets, edge <- ElixirCallIndex.exact_callers(index, qn), do: {edge, qn, "exact"}
    fallback = for qn <- targets, edge <- ElixirCallIndex.fallback_callers(index, qn), do: {edge, qn, "fallback"}

    (exact ++ fallback)
    |> Enum.uniq_by(fn {edge, qn, _} ->
      {ElixirCallIndex.identity(edge.caller), edge.caller.entity["file_path"], qn}
    end)
    |> Enum.sort_by(fn {edge, _qn, match} ->
      {match != "exact", edge.caller.entity["file_path"] || "", edge.caller.entity["start_line"] || 0}
    end)
  end

  defp elixir_caller_result({%{caller: caller, call: call}, qn, match}) do
    entity = caller.entity

    %{
      id: caller.id,
      score: 0.0,
      entity: %{
        "name" => entity["name"],
        "qualified_name" => ElixirCallIndex.identity(caller),
        "file_path" => entity["file_path"],
        "entity_type" => entity["entity_type"],
        "start_line" => entity["start_line"] || 0,
        "end_line" => entity["end_line"] || 0,
        "calls" => [call],
        "is_a" => entity["is_a"] || [],
        "contains" => entity["contains"] || [],
        "resolves_to" => qn,
        "match" => match
      }
    }
  end

  defp find_callers_by_name(entity_name, limit) do
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
      case DataFetching.get_all_entities_cached(:all) do
        {:ok, all_entities} ->
          results
          |> refine_entities_to_functions(entity_name, all_entities)
          |> Enum.uniq_by(& &1.id)
          |> drop_module_callers_with_function_sibling()
          |> disambiguate_definitions(entity_name, all_entities)

        _ ->
          results
          |> drop_module_callers_with_function_sibling()
      end

    {:ok, refined}
  end

  # When several files define the queried name (gpt_alpha/training.py and
  # jepa/text_jepa/training.py both define save_checkpoint), tag each caller with
  # the definition it uses (`resolves_to`), and for a qualified query
  # (`text_jepa.save_checkpoint`) keep only that definition's callers.
  defp disambiguate_definitions(callers, entity_name, all_entities) do
    short = entity_name |> String.split(".") |> List.last() |> String.downcase()

    definitions =
      all_entities
      |> Enum.filter(fn e ->
        e.entity["entity_type"] in ["function", "method", "class"] and
          (e.entity["name"] || "") |> String.split(".") |> List.last() |> String.downcase() == short
      end)
      |> Enum.map(& &1.entity["file_path"])
      |> Enum.uniq()

    if length(definitions) < 2 do
      callers
    else
      tagged =
        Enum.map(callers, fn caller ->
          put_in(caller, [:entity, "resolves_to"], resolve_definition(caller.entity, short, definitions))
        end)

      case String.split(entity_name, ".") do
        [_bare] ->
          tagged

        parts ->
          qualifier = parts |> Enum.drop(-1) |> Enum.join("/") |> String.downcase()
          Enum.filter(tagged, &String.contains?(String.downcase(&1.entity["resolves_to"] || ""), qualifier))
      end
    end
  end

  defp resolve_definition(caller, short, definitions) do
    call =
      Enum.find(caller["calls"] || [], fn c ->
        c |> String.split(".") |> List.last() |> String.downcase() == short
      end)

    qualifier =
      case call && String.split(call, ".") do
        parts when is_list(parts) and length(parts) > 1 ->
          parts |> Enum.drop(-1) |> Enum.join("/") |> String.downcase()

        _ ->
          nil
      end

    module_of = fn path -> path |> Path.rootname() |> String.downcase() end

    by_qualifier = qualifier && Enum.find(definitions, &String.contains?(module_of.(&1), qualifier))

    by_import =
      Enum.find(definitions, fn def_path ->
        Enum.any?(caller["is_a"] || [], fn import ->
          String.ends_with?(module_of.(def_path), import |> String.replace(".", "/") |> String.downcase())
        end)
      end)

    by_qualifier || by_import ||
      Enum.max_by(definitions, &shared_dir_depth(&1, caller["file_path"] || ""))
  end

  defp shared_dir_depth(a, b) do
    Path.split(Path.dirname(a))
    |> Enum.zip(Path.split(Path.dirname(b)))
    |> Enum.take_while(fn {x, y} -> x == y end)
    |> length()
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

  # Drop module-type callers when a function/method caller from the same file is
  # already present. This prevents the file-level module entity (which aggregates
  # all imports as calls) from appearing alongside its enclosing function.
  defp drop_module_callers_with_function_sibling(results) do
    function_files =
      results
      |> Enum.filter(fn r ->
        (r.entity["entity_type"] || "") in ["function", "method"]
      end)
      |> MapSet.new(fn r -> r.entity["file_path"] end)

    Enum.reject(results, fn r ->
      (r.entity["entity_type"] || "") == "module" and
        MapSet.member?(function_files, r.entity["file_path"])
    end)
  end
end
