defmodule ElixirNexus.Search.ElixirDeadCode do
  @moduledoc """
  Dead-code verdicts for Elixir functions over the exact call graph
  (`ElixirNexus.Search.ElixirCallIndex`).

  A public function is:

    * alive when an exact call reaches one of its qualified names from another
      function (recursion does not count);
    * `unsure` when only a fallback could reach it: a call on a variable module
      (`mod.fun(x)`), `apply` with a variable function, an ambiguous alias, or its
      name as an atom next to its module (`{Mod, :fun}` with no tuple, `:fun` passed
      to a dispatcher). The entry says which;
    * dead otherwise.

  Functions are judged once per qualified-name set, not once per clause.
  """

  alias ElixirNexus.Search.ElixirCallIndex

  # Callbacks a framework calls. Each is `{arities, behaviours}`: the function is a
  # callback only in a module that `use`s or `@behaviour`s something, and, when
  # `behaviours` is non-empty, one of those. `@impl` makes the list moot where used.
  @callbacks %{
    "init" => {[1], []},
    "terminate" => {[2], []},
    "code_change" => {[3], []},
    "child_spec" => {:any, []},
    "start_link" => {:any, []},
    "handle_call" => {[3], []},
    "handle_cast" => {[2], []},
    "handle_info" => {[2], []},
    "handle_continue" => {[2], []},
    "handle_demand" => {[2], []},
    "handle_subscribe" => {[4], []},
    "handle_cancel" => {[3], []},
    "handle_events" => {[3], []},
    "handle_message" => {[3], []},
    "handle_batch" => {[4], []},
    "handle_failed" => {[2], []},
    "format_status" => {[1, 2], []},
    "mount" => {[3], []},
    # render/1 for LiveViews and components; render/2 for Phoenix views (ErrorHTML, ErrorJSON).
    "render" => {[1, 2], []},
    "update" => {[2], []},
    "update_many" => {[1], []},
    "handle_params" => {[3], []},
    "handle_event" => {[3], []},
    "handle_async" => {[3], []},
    "on_mount" => {[4], []},
    "call" => {[2], []},
    "join" => {[3], []},
    "handle_in" => {[3], []},
    "handle_out" => {[3], []},
    "start" => {[2], ["Application"]},
    "stop" => {[1], ["Application"]},
    "prep_stop" => {[1], ["Application"]},
    "config_change" => {[3], ["Application"]},
    "run" => {[1], ["Mix.Task"]},
    "project" => {[0], ["Mix.Project"]},
    "application" => {[0], ["Mix.Project"]},
    "cli" => {[0], ["Mix.Project"]},
    "type" => {[0, 1], ["Ecto.Type", "Ecto.ParameterizedType"]},
    "cast" => {[1, 2], ["Ecto.Type", "Ecto.ParameterizedType"]},
    "load" => {[1, 3], ["Ecto.Type", "Ecto.ParameterizedType"]},
    "dump" => {[1, 3], ["Ecto.Type", "Ecto.ParameterizedType"]},
    "embed_as" => {[1, 2], ["Ecto.Type", "Ecto.ParameterizedType"]},
    "equal?" => {[2, 3], ["Ecto.Type", "Ecto.ParameterizedType"]}
  }

  @doc """
  Judge `candidates` (public Elixir function entities already filtered for entry
  points, test files and controllers). Returns `{dead, dead_via_dead_callers, unsure}`.

  Liveness is reachability: a function is alive when a call reaches it from
  something that is not itself a suspect (a callback, an entry point, a module
  body, a function outside the candidates, a test when tests count), directly or
  through other live functions. Private functions are links in that graph but
  are never reported. What no live caller reaches is:

    * `unsure` when it has its own unsure reason (a fallback edge, an atom
      mention) or is reached from an unsure function: a function called only by
      something unsure stays unsure;
    * dead when nothing calls it (the `dead` list);
    * dead via dead callers otherwise: every caller is dead, as in a chain under
      a dead function or a cycle no live code enters. Each entry carries its
      `dead_callers` and one `chain` of calls leading to it.
  """
  def judge(candidates, all_entities, index, count_test_callers?, config \\ nil) do
    groups =
      candidates
      |> Enum.reject(&(ElixirCallIndex.qualified_names(&1) == []))
      |> group_functions()
      |> Enum.reject(&callback?(&1, index))
      |> Enum.reject(fn e ->
        Enum.any?(ElixirCallIndex.qualified_names(e), &ElixirNexus.ProjectConfig.entry_function?(config, &1))
      end)

    privates =
      all_entities
      |> Enum.filter(fn e ->
        ElixirCallIndex.xref?(e) and e.entity["visibility"] == "private" and e.entity["entity_type"] == "function"
      end)
      |> Enum.reject(&(ElixirCallIndex.qualified_names(&1) == []))
      |> group_functions()

    graph = suspect_graph(groups ++ privates, index, count_test_callers?)
    live = reach(graph, Map.keys(graph.nodes) |> Enum.filter(&(graph.nodes[&1].root? == true)))

    public_left = Enum.reject(groups, &MapSet.member?(live, &1.id))
    mentions = atom_mentions(public_left, all_entities)

    own_reasons =
      for e <- public_left, reason = unsure_reason(e, index, mentions), into: %{}, do: {e.id, reason}

    maybe = reach(graph, Map.keys(own_reasons), live)

    {dead, via, unsure} =
      Enum.reduce(public_left, {[], [], []}, fn e, {dead, via, unsure} ->
        node = graph.nodes[e.id]

        cond do
          reason = own_reasons[e.id] ->
            {dead, via, [unsure_entry(e, reason) | unsure]}

          MapSet.member?(maybe, e.id) ->
            from = node.callers |> Enum.find(&MapSet.member?(maybe, &1)) |> then(&graph.nodes[&1].entity)

            reason =
              "called only from code that is itself unsure or dead; reached from #{ElixirCallIndex.identity(from)}"

            {dead, via, [unsure_entry(e, reason) | unsure]}

          node.callers == [] ->
            {[dead_entry(e, node.test_callers?) | dead], via, unsure}

          true ->
            {dead, [via_entry(e, node, graph) | via], unsure}
        end
      end)

    {sort(dead), sort(via), sort(unsure)}
  end

  defp group_functions(entities) do
    entities
    |> Enum.group_by(&{&1.entity["file_path"], &1.entity["module_path"], &1.entity["name"]})
    |> Enum.flat_map(fn {_key, clauses} -> functions(clauses) end)
  end

  # Every suspect function (public candidates and private functions) with its
  # callers among the suspects, and whether anything else calls it (`root?`).
  # A caller outside the suspects is live by assumption: a callback, an entry
  # point, a module body, a non-candidate. Test callers make a root only when
  # tests count; otherwise they are ignored here and flagged `test_callers?`.
  defp suspect_graph(suspects, index, count_test_callers?) do
    owner =
      for e <- suspects, qn <- ElixirCallIndex.qualified_names(e), into: %{}, do: {qn, e.id}

    nodes =
      Map.new(suspects, fn e ->
        edges =
          e
          |> ElixirCallIndex.qualified_names()
          |> Enum.flat_map(&ElixirCallIndex.exact_callers(index, &1))

        {test_edges, app_edges} = Enum.split_with(edges, &ElixirCallIndex.test_caller?/1)

        {callers, outside} =
          Enum.reduce(app_edges, {[], false}, fn %{caller: caller}, {callers, outside} ->
            case Enum.find_value(ElixirCallIndex.qualified_names(caller), &owner[&1]) do
              nil -> {callers, true}
              id when id == e.id -> {callers, outside}
              id -> {[id | callers], outside}
            end
          end)

        root? = outside or (count_test_callers? and test_edges != [])
        {e.id, %{entity: e, callers: Enum.uniq(callers), root?: root?, test_callers?: test_edges != []}}
      end)

    callees =
      Enum.reduce(nodes, %{}, fn {id, node}, acc ->
        Enum.reduce(node.callers, acc, fn caller, acc -> Map.update(acc, caller, [id], &[id | &1]) end)
      end)

    %{nodes: nodes, callees: callees}
  end

  # Everything reachable along calls from `start`, never entering `blocked`.
  defp reach(graph, start, blocked \\ MapSet.new()) do
    start = Enum.reject(start, &MapSet.member?(blocked, &1))
    do_reach(graph, start, MapSet.new(start), blocked)
  end

  defp do_reach(_graph, [], seen, _blocked), do: seen

  defp do_reach(graph, [id | rest], seen, blocked) do
    next =
      graph.callees
      |> Map.get(id, [])
      |> Enum.reject(&(MapSet.member?(seen, &1) or MapSet.member?(blocked, &1)))

    do_reach(graph, next ++ rest, Enum.reduce(next, seen, &MapSet.put(&2, &1)), blocked)
  end

  # One chain of dead calls ending at `node`: walk up through the first caller
  # until a function nothing calls, or until the walk comes back (a cycle).
  defp chain(node, graph), do: do_chain(node, graph, [node.entity.id], [ElixirCallIndex.identity(node.entity)])

  defp do_chain(%{callers: []}, _graph, _seen, names), do: names

  defp do_chain(%{callers: [caller | _]}, graph, seen, names) do
    up = graph.nodes[caller]
    name = ElixirCallIndex.identity(up.entity)

    if caller in seen,
      do: [name <> " (cycle)" | names],
      else: do_chain(up, graph, [caller | seen], [name | names])
  end

  defp via_entry(e, node, graph) do
    e
    |> dead_entry(node.test_callers?)
    |> Map.put(
      :dead_callers,
      node.callers |> Enum.map(&ElixirCallIndex.identity(graph.nodes[&1].entity)) |> Enum.sort()
    )
    |> Map.put(:chain, chain(node, graph))
  end

  # The clauses of one function, as one entity: clauses whose arities overlap are
  # the same function. A bodiless head with defaults (`def f(a, b \\ 1)`, arities
  # 1 and 2) and the clauses after it (arity 2) are one function, called as f/1 or f/2.
  defp functions(clauses) do
    clauses
    |> Enum.sort_by(&(&1.entity["start_line"] || 0))
    |> Enum.reduce([], fn clause, groups ->
      names = MapSet.new(ElixirCallIndex.qualified_names(clause))
      {overlapping, rest} = Enum.split_with(groups, fn {set, _} -> not MapSet.disjoint?(set, names) end)
      merged_set = Enum.reduce(overlapping, names, fn {set, _}, acc -> MapSet.union(set, acc) end)
      merged_members = Enum.flat_map(overlapping, &elem(&1, 1)) ++ [clause]
      [{merged_set, merged_members} | rest]
    end)
    |> Enum.map(fn {set, [first | _] = members} ->
      xref =
        first.entity["xref"]
        |> Map.put("qualified_names", set |> MapSet.to_list() |> Enum.sort())
        |> Map.put("callback", Enum.any?(members, &(&1.entity["xref"]["callback"] == true)))

      end_line = members |> Enum.map(&(&1.entity["end_line"] || 0)) |> Enum.max()
      %{first | entity: first.entity |> Map.put("xref", xref) |> Map.put("end_line", end_line)}
    end)
  end

  defp sort(entries), do: Enum.sort_by(entries, &{&1.file_path, &1.start_line})

  defp dead_entry(e, called_from_tests?) do
    %{
      name: e.entity["name"],
      qualified_name: ElixirCallIndex.identity(e),
      file_path: e.entity["file_path"],
      entity_type: e.entity["entity_type"],
      start_line: e.entity["start_line"],
      called_from_tests: called_from_tests?
    }
  end

  defp unsure_entry(e, reason) do
    %{
      name: e.entity["name"],
      qualified_name: ElixirCallIndex.identity(e),
      file_path: e.entity["file_path"],
      entity_type: e.entity["entity_type"],
      start_line: e.entity["start_line"],
      reason: reason
    }
  end

  defp callback?(e, index) do
    xref = e.entity["xref"]

    xref["callback"] == true or
      Enum.any?(ElixirCallIndex.qualified_names(e), fn qn ->
        {module, name, arity} = ElixirCallIndex.split_qname(qn)
        info = Map.get(index.module_info, module, %{})
        frameworks = List.wrap(info["uses"]) ++ List.wrap(info["behaviours"])

        case Map.get(@callbacks, name) do
          # Phoenix calls render/2 of a view module (ErrorHTML, ErrorJSON via render_errors).
          _ when name == "render" and arity == 2 ->
            String.ends_with?(module, ["HTML", "JSON"])

          nil ->
            false

          {arities, required} ->
            frameworks != [] and (arities == :any or arity in arities) and
              (required == [] or Enum.any?(required, &(&1 in frameworks)))
        end
      end)
  end

  defp unsure_reason(e, index, mentions) do
    qns = ElixirCallIndex.qualified_names(e)

    case Enum.flat_map(qns, &ElixirCallIndex.fallback_callers(index, &1)) do
      [%{caller: caller, call: call} | _] ->
        "only a short-name match: `#{call}` in #{ElixirCallIndex.identity(caller)} (#{caller.entity["file_path"]})"

      [] ->
        case Map.get(mentions, e.id) do
          nil -> nil
          {file, line} -> "its name is an atom or keyword next to its module at #{file}:#{line} (dynamic dispatch?)"
        end
    end
  end

  # Evidence a function is reached by name without a call the graph can see:
  # `:fun` on a line that also names the function's module (its last alias
  # segment, or __MODULE__ inside it), as in `Process.send(Mod, :fun)` or a
  # dispatch table; or `fun: Mod` (the module is the option's value, as in
  # `metrics: MyApp.Telemetry`). Lines inside the function itself do not count.
  # Returns %{entity_id => {file, line}} for the first mention.
  defp atom_mentions([], _all), do: %{}

  defp atom_mentions(candidates, all_entities) do
    names = MapSet.new(candidates, & &1.entity["name"])

    lines =
      all_entities
      |> Enum.filter(&ElixirCallIndex.xref?/1)
      |> Enum.flat_map(fn e ->
        content = e.entity["content"] || ""
        start = e.entity["start_line"] || 1

        if String.contains?(content, ":") do
          content
          |> String.split("\n")
          |> Enum.with_index(start)
          |> Enum.flat_map(&line_mentions(&1, names, e.entity["file_path"]))
        else
          []
        end
      end)
      |> Enum.uniq()
      |> Enum.group_by(&elem(&1, 0))

    Enum.reduce(candidates, %{}, fn e, acc ->
      {module, _name, _arity} = e |> ElixirCallIndex.qualified_names() |> hd() |> ElixirCallIndex.split_qname()
      last = module |> String.split(".") |> List.last()
      file = e.entity["file_path"]
      own = (e.entity["start_line"] || 0)..(e.entity["end_line"] || 0)//1

      hit =
        lines
        |> Map.get(e.entity["name"], [])
        |> Enum.find(fn {_name, f, line, kind} ->
          not (f == file and line in own) and mentions_module?(kind, last, f == file)
        end)

      case hit do
        nil -> acc
        {_name, f, line, _kind} -> Map.put(acc, e.id, {f, line})
      end
    end)
  end

  defp line_mentions({text, line}, names, file) do
    atoms =
      ~r/(?<![:\w]):([a-z_][a-zA-Z0-9_]*[?!]?)/
      |> Regex.scan(text, capture: :all_but_first)
      |> Enum.map(fn [name] -> {name, file, line, {:atom, text}} end)

    keywords =
      ~r/(?<![:\w.])([a-z_][a-zA-Z0-9_]*[?!]?):\s+((?:[A-Z][a-zA-Z0-9_]*\.)*[A-Z][a-zA-Z0-9_]*)\b/
      |> Regex.scan(text, capture: :all_but_first)
      |> Enum.map(fn [name, mod] -> {name, file, line, {:keyword, mod}} end)

    Enum.filter(atoms ++ keywords, fn {name, _, _, _} -> MapSet.member?(names, name) end)
  end

  defp mentions_module?({:atom, text}, last, same_file?),
    do: Regex.match?(~r/\b#{Regex.escape(last)}\b/, text) or (same_file? and String.contains?(text, "__MODULE__"))

  defp mentions_module?({:keyword, mod}, last, _same_file?), do: mod |> String.split(".") |> List.last() == last
end
