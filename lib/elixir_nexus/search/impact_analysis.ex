defmodule ElixirNexus.Search.ImpactAnalysis do
  @moduledoc "Transitive impact analysis — find everything affected by changing a given entity."

  alias ElixirNexus.Search.{CallerFinder, DataFetching, ElixirCallIndex}

  @doc """
  Transitive impact analysis: given a function, find everything that would be
  affected by changing it — callers, their callers, etc. up to `depth` levels.
  Returns a tree of impact with file/line info.
  """
  def analyze_impact(entity_name, depth \\ 3) do
    require Logger
    Logger.info("Analyzing impact of: #{entity_name}, depth: #{depth}")

    case DataFetching.get_all_entities_cached(:all) do
      {:ok, all_entities} ->
        case elixir_targets(all_entities, entity_name) do
          {index, [_ | _] = targets} -> {:ok, elixir_impact(index, entity_name, targets, depth)}
          _ -> legacy_impact(all_entities, entity_name, depth)
        end

      error ->
        error
    end
  end

  defp elixir_targets(all_entities, entity_name) do
    if Enum.any?(all_entities, &ElixirCallIndex.xref?/1) do
      index = ElixirCallIndex.build(all_entities)
      {index, ElixirCallIndex.targets(index, entity_name)}
    end
  end

  # Exact Elixir impact: callers by qualified name, transitively. Each node is
  # named by its qualified name; `match` says whether the edge is exact or only a
  # short-name fallback (a call on a variable module).
  defp elixir_impact(index, root, targets, depth) do
    tree = elixir_tree(index, targets, depth, MapSet.new(targets))
    flat = flatten_impact_tree(tree)

    %{
      root: root,
      resolved_to: targets,
      depth: depth,
      total_affected: length(flat),
      impact: tree,
      affected_files: flat |> Enum.map(& &1.file_path) |> Enum.uniq()
    }
  end

  defp elixir_tree(_index, _targets, 0, _visited), do: []

  defp elixir_tree(index, targets, depth, visited) do
    index
    |> CallerFinder.elixir_caller_edges(targets)
    |> Enum.uniq_by(fn {edge, _qn, _match} -> ElixirCallIndex.identity(edge.caller) end)
    |> Enum.reject(fn {edge, _qn, _match} -> MapSet.member?(visited, ElixirCallIndex.identity(edge.caller)) end)
    |> Enum.map(fn {%{caller: caller}, _qn, match} ->
      name = ElixirCallIndex.identity(caller)
      next = ElixirCallIndex.qualified_names(caller)

      %{
        name: name,
        file_path: caller.entity["file_path"],
        entity_type: caller.entity["entity_type"],
        start_line: caller.entity["start_line"],
        end_line: caller.entity["end_line"],
        match: match,
        affected_by: if(next == [], do: [], else: elixir_tree(index, next, depth - 1, MapSet.put(visited, name)))
      }
    end)
  end

  defp legacy_impact(all_entities, entity_name, depth) do
    # Build reverse edge index once: name_lower -> [referencing_entities]
    # Includes both calls and imports so import-only dependencies are tracked
    edge_index = build_reverse_edge_index(all_entities)
    tree = build_impact_tree(entity_name, edge_index, depth, MapSet.new(), all_entities)
    flat = flatten_impact_tree(tree)

    {:ok,
     %{
       root: entity_name,
       depth: depth,
       total_affected: length(flat),
       impact: tree,
       affected_files: flat |> Enum.map(& &1.file_path) |> Enum.uniq()
     }}
  end

  # Build a reverse edge index: for each call or import name, list the entities that reference it.
  # This turns O(n) caller lookups into O(1) map lookups.
  # Indexes both `calls` (runtime invocations) and `is_a` (imports/dependencies).
  defp build_reverse_edge_index(entities) do
    Enum.reduce(entities, %{}, fn e, acc ->
      calls = e.entity["calls"] || []
      imports = e.entity["is_a"] || []

      acc =
        Enum.reduce(calls, acc, fn call, index ->
          key = String.downcase(call)
          Map.update(index, key, [e], fn existing -> [e | existing] end)
        end)

      Enum.reduce(imports, acc, fn imp, index ->
        key = String.downcase(imp)
        Map.update(index, key, [e], fn existing -> [e | existing] end)
      end)
    end)
  end

  defp build_impact_tree(_name, _call_index, 0, _visited, _all_entities), do: []

  defp build_impact_tree(name, call_index, depth, visited, all_entities) do
    name_lower = String.downcase(name)

    # Find callers via index: exact match + partial matches (Module.func -> func)
    callers =
      call_index
      |> Enum.flat_map(fn {call_lower, caller_entities} ->
        if call_lower == name_lower or
             String.ends_with?(call_lower, "." <> name_lower) or
             String.ends_with?(name_lower, "." <> call_lower) do
          caller_entities
        else
          []
        end
      end)
      # Dedupe and track `visited` by {name, file_path}, NOT bare name. Same-named functions
      # are everywhere in real codebases (every Next.js route.ts has GET/POST/PUT/DELETE); a
      # name-only key collapsed all `POST` callers into one and stopped traversal after the
      # first, so analyze_impact under-reported the blast radius vs find_all_callers.
      |> Enum.uniq_by(&entity_key/1)
      |> Enum.reject(fn e -> MapSet.member?(visited, entity_key(e)) end)
      |> CallerFinder.refine_entities_to_functions(name_lower, all_entities)

    Enum.map(callers, fn caller ->
      caller_name = caller.entity["name"]
      new_visited = MapSet.put(visited, entity_key(caller))

      %{
        name: caller_name,
        file_path: caller.entity["file_path"],
        entity_type: caller.entity["entity_type"],
        start_line: caller.entity["start_line"],
        end_line: caller.entity["end_line"],
        affected_by: build_impact_tree(caller_name, call_index, depth - 1, new_visited, all_entities)
      }
    end)
  end

  # A caller's identity for dedup/visited — name alone collides across files.
  defp entity_key(e), do: {e.entity["name"], e.entity["file_path"]}

  defp flatten_impact_tree(tree) do
    Enum.flat_map(tree, fn node ->
      [%{name: node.name, file_path: node.file_path} | flatten_impact_tree(node.affected_by)]
    end)
  end
end
