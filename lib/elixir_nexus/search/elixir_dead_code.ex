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
    "render" => {[1], []},
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
    "type" => {[0, 1], ["Ecto.Type", "Ecto.ParameterizedType"]},
    "cast" => {[1, 2], ["Ecto.Type", "Ecto.ParameterizedType"]},
    "load" => {[1, 3], ["Ecto.Type", "Ecto.ParameterizedType"]},
    "dump" => {[1, 3], ["Ecto.Type", "Ecto.ParameterizedType"]},
    "embed_as" => {[1, 2], ["Ecto.Type", "Ecto.ParameterizedType"]},
    "equal?" => {[2, 3], ["Ecto.Type", "Ecto.ParameterizedType"]}
  }

  @doc """
  Judge `candidates` (public Elixir function entities already filtered for entry
  points, test files and controllers). Returns `{dead, unsure}`.
  """
  def judge(candidates, all_entities, index, count_test_callers?) do
    groups =
      candidates
      |> Enum.reject(&callback?(&1, index))
      |> Enum.group_by(&{&1.entity["file_path"], ElixirCallIndex.qualified_names(&1)})
      |> Enum.map(fn {_key, clauses} -> Enum.min_by(clauses, &(&1.entity["start_line"] || 0)) end)
      |> Enum.reject(&(ElixirCallIndex.qualified_names(&1) == []))

    {alive_or_pending, dead_by_tests} =
      Enum.reduce(groups, {[], []}, fn e, {pending, test_only} ->
        edges = Enum.flat_map(ElixirCallIndex.qualified_names(e), &ElixirCallIndex.exact_callers(index, &1))
        {test_edges, app_edges} = Enum.split_with(edges, &ElixirCallIndex.test_caller?/1)

        cond do
          app_edges != [] -> {pending, test_only}
          test_edges != [] and count_test_callers? -> {pending, test_only}
          test_edges != [] -> {pending, [e | test_only]}
          true -> {[e | pending], test_only}
        end
      end)

    candidates_left = alive_or_pending ++ dead_by_tests
    tested = MapSet.new(dead_by_tests, & &1.id)
    mentions = atom_mentions(candidates_left, all_entities)

    {dead, unsure} =
      Enum.reduce(candidates_left, {[], []}, fn e, {dead, unsure} ->
        case unsure_reason(e, index, mentions) do
          nil -> {[dead_entry(e, MapSet.member?(tested, e.id)) | dead], unsure}
          reason -> {dead, [unsure_entry(e, reason) | unsure]}
        end
      end)

    {sort(dead), sort(unsure)}
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
          {file, line} -> "its name is an atom next to its module at #{file}:#{line} (dynamic dispatch?)"
        end
    end
  end

  # `:fun` on a line that also names the function's module (its last alias
  # segment, or __MODULE__ inside it): `Map.get(handlers, :fun)` near `Mod`,
  # `Process.send(Mod, :fun)`, a dispatch table. Lines inside the function itself
  # do not count. Returns %{entity_id => {file, line}} for the first mention.
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
          |> Enum.flat_map(fn {text, line} ->
            ~r/(?<![:\w]):([a-z_][a-zA-Z0-9_]*[?!]?)/
            |> Regex.scan(text, capture: :all_but_first)
            |> Enum.map(fn [atom] -> atom end)
            |> Enum.filter(&MapSet.member?(names, &1))
            |> Enum.map(&{&1, e.entity["file_path"], line, text})
          end)
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
        |> Enum.find(fn {_atom, f, line, text} ->
          not (f == file and line in own) and
            (Regex.match?(~r/\b#{Regex.escape(last)}\b/, text) or (f == file and String.contains?(text, "__MODULE__")))
        end)

      case hit do
        nil -> acc
        {_atom, f, line, _text} -> Map.put(acc, e.id, {f, line})
      end
    end)
  end
end
