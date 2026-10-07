defmodule ElixirNexus.Search.ElixirCallIndex do
  @moduledoc """
  The exact Elixir call graph, built from the `xref` the parser records
  (`ElixirNexus.Parsers.ElixirXref`): every definition by its qualified name
  (`Mod.fun/arity`) and every call resolved to the definitions it reaches.

  Resolution of a call string (see `ElixirXref` for the forms):

    * `Mod.fun/2`: the definition, if `Mod` is a project module. An unknown `Mod`
      is expanded through the aliases the caller's `use`s inject, then by suffix
      (`Layouts` -> the one project module ending in `.Layouts`). Several suffix
      matches leave it ambiguous (a fallback limited to those modules).
    * `fun/2`: the caller's own module, then its imports, then the imports its
      `use`s inject (transitively). Nothing found means a call to a dependency
      or Kernel, unless the module imports something dynamically (a fallback).
    * `Mod.fun/*`: every arity of `Mod.fun`. `Mod.*/0`: any function of `Mod` of
      arity 0 (a fallback).
    * `?fun/2`: a call on a variable module; only name and arity are known (a fallback).

  A fallback never makes a definition "called"; it makes it `unsure`.
  Entities without `xref` (older indexes, other languages) are not in the
  exact graph; their calls count only as fallback evidence.
  """

  alias ElixirNexus.Search.EntityResolution

  defstruct defs: %{},
            by_name: %{},
            modules: MapSet.new(),
            by_last_segment: %{},
            module_info: %{},
            injected: %{},
            exact: %{},
            fallback: [],
            stats: %{"exact" => 0, "fallback" => 0, "external" => 0}

  @type t :: %__MODULE__{}

  @doc "True when the entity carries Elixir call-graph data."
  def xref?(%{entity: entity}), do: entity["language"] == "elixir" and is_map(entity["xref"])
  def xref?(_), do: false

  @doc "The entity's qualified names (`Mod.fun/arity`), or []."
  def qualified_names(%{entity: entity}), do: (entity["xref"] || %{})["qualified_names"] || []

  @doc "A caller's display identity: its first qualified name, else its module."
  def identity(%{entity: entity} = e) do
    case qualified_names(e) do
      [qn | _] -> qn
      [] -> (entity["xref"] || %{})["module"] || entity["name"]
    end
  end

  @doc "Build the index from every entity (from `DataFetching.get_all_entities_cached(:all)`)."
  def build(all_entities) do
    xref_entities = Enum.filter(all_entities, &xref?/1)

    defs =
      Enum.reduce(xref_entities, %{}, fn e, acc ->
        Enum.reduce(qualified_names(e), acc, fn qn, acc -> Map.update(acc, qn, [e], &(&1 ++ [e])) end)
      end)

    module_info =
      for e <- xref_entities, mod = e.entity["xref"]["module"], is_binary(mod), into: %{} do
        {mod, e.entity["xref"]}
      end

    modules =
      defs
      |> Map.keys()
      |> Enum.map(&(&1 |> split_qname() |> elem(0)))
      |> Enum.concat(Map.keys(module_info))
      |> MapSet.new()

    by_last_segment = Enum.group_by(modules, &(&1 |> String.split(".") |> List.last()))

    by_name =
      defs
      |> Map.keys()
      |> Enum.group_by(&(&1 |> split_qname() |> elem(1) |> String.downcase()))

    index = %__MODULE__{
      defs: defs,
      by_name: by_name,
      modules: modules,
      by_last_segment: by_last_segment,
      module_info: module_info
    }

    index = %{index | injected: Map.new(modules, &{&1, injected(&1, index, MapSet.new())})}

    index =
      Enum.reduce(xref_entities, index, fn caller, index ->
        own = MapSet.new(qualified_names(caller))

        caller.entity["xref"]["calls"]
        |> List.wrap()
        |> Enum.reduce(index, fn call, index -> add_call(index, caller, call, own) end)
      end)

    all_entities
    |> Enum.reject(&xref?/1)
    |> Enum.filter(&(&1.entity["language"] == "elixir"))
    |> Enum.reduce(index, fn caller, index ->
      Enum.reduce(caller.entity["calls"] || [], index, fn call, index ->
        name = call |> String.split(".") |> List.last()
        edge = %{caller: caller, call: call, key: %{module: nil, name: name, arity: "*"}}
        %{index | fallback: [edge | index.fallback]}
      end)
    end)
  end

  defp add_call(index, caller, call, own) do
    case resolve(index, call, caller) do
      {:exact, qns} ->
        qns
        |> Enum.reject(&MapSet.member?(own, &1))
        |> Enum.reduce(bump(index, "exact"), fn qn, index ->
          edge = %{caller: caller, call: call}
          %{index | exact: Map.update(index.exact, qn, [edge], &[edge | &1])}
        end)

      {:fallback, key} ->
        edge = %{caller: caller, call: call, key: key}
        %{bump(index, "fallback") | fallback: [edge | index.fallback]}

      :external ->
        bump(index, "external")
    end
  end

  defp bump(index, key), do: %{index | stats: Map.update!(index.stats, key, &(&1 + 1))}

  @doc """
  Resolve one call string made by `caller`: `{:exact, [qualified_name]}`,
  `{:fallback, key}` (only a name/arity match can say), or `:external`.
  """
  def resolve(_index, "?" <> rest, _caller) do
    {_mod, name, arity} = split_qname(rest)
    {:fallback, %{module: nil, name: name, arity: arity}}
  end

  def resolve(index, call, caller) do
    case split_qname(call) do
      {nil, name, arity} -> resolve_bare(index, name, arity, caller)
      {mod, name, arity} -> resolve_remote(index, mod, name, arity, caller)
    end
  end

  defp resolve_remote(index, mod, name, arity, caller) do
    case candidate_modules(index, mod, caller) do
      [] ->
        :external

      [module] when name != "*" ->
        case matching(index, module, name, arity) do
          [] -> :external
          qns -> {:exact, qns}
        end

      [module] ->
        if matching(index, module, name, arity) == [],
          do: :external,
          else: {:fallback, %{module: [module], name: name, arity: arity}}

      several ->
        case Enum.filter(several, &(matching(index, &1, name, arity) != [])) do
          [] -> :external
          [module] when name != "*" -> {:exact, matching(index, module, name, arity)}
          defining -> {:fallback, %{module: defining, name: name, arity: arity}}
        end
    end
  end

  defp candidate_modules(index, mod, caller) do
    cond do
      MapSet.member?(index.modules, mod) ->
        [mod]

      (expanded = expand_injected_alias(index, mod, caller)) != nil ->
        [expanded]

      true ->
        last = mod |> String.split(".") |> List.last()

        index.by_last_segment
        |> Map.get(last, [])
        |> Enum.filter(&String.ends_with?(&1, "." <> mod))
    end
  end

  defp expand_injected_alias(index, mod, caller) do
    [first | rest] = String.split(mod, ".")
    aliases = index.injected |> Map.get(caller_module(caller), %{}) |> Map.get(:aliases, %{})

    with full when is_binary(full) <- Map.get(aliases, first),
         expanded = Enum.join([full | rest], "."),
         true <- MapSet.member?(index.modules, expanded) do
      expanded
    else
      _ -> nil
    end
  end

  defp resolve_bare(index, name, arity, caller) do
    module = caller_module(caller)
    info = Map.get(index.module_info, module)
    injected = Map.get(index.injected, module, %{imports: []})

    sources =
      [module] ++
        List.wrap(caller.entity["xref"]["imports"]) ++
        List.wrap(info && info["imports"]) ++ injected.imports

    case Enum.find_value(Enum.uniq(sources), &non_empty(matching(index, &1, name, arity))) do
      nil ->
        # An unknown module context (not indexed) or a dynamic import could hide the target.
        if info == nil or info["dynamic_imports"],
          do: {:fallback, %{module: nil, name: name, arity: arity}},
          else: :external

      qns ->
        {:exact, qns}
    end
  end

  defp non_empty([]), do: nil
  defp non_empty(list), do: list

  defp caller_module(%{entity: entity}), do: entity["module_path"] || (entity["xref"] || %{})["module"]

  # Definitions of `module.name/arity`; `*` matches any name or arity.
  defp matching(_index, nil, _name, _arity), do: []

  defp matching(index, module, name, arity) when name != "*" and arity != "*" do
    qn = "#{module}.#{name}/#{arity}"
    if Map.has_key?(index.defs, qn), do: [qn], else: []
  end

  defp matching(index, module, name, arity) do
    index.defs
    |> Map.keys()
    |> Enum.filter(fn qn ->
      {m, n, a} = split_qname(qn)
      m == module and (name == "*" or n == name) and (arity == "*" or a == arity)
    end)
    |> Enum.sort()
  end

  # What `use Mod` brings into a module: the imports and aliases in Mod's quotes,
  # and in the quotes of the modules Mod's quotes `use`, transitively.
  defp injected(module, index, seen) do
    info = Map.get(index.module_info, module, %{})

    {imports, aliases} =
      (info["uses"] || [])
      |> Enum.reject(&MapSet.member?(seen, &1))
      |> Enum.reduce({[], %{}}, fn used, {imports, aliases} ->
        {i, a} = injects_of(used, index, MapSet.put(seen, used))
        {imports ++ i, Map.merge(aliases, a)}
      end)

    %{imports: Enum.uniq(imports), aliases: aliases}
  end

  defp injects_of(module, index, seen) do
    injects = (Map.get(index.module_info, module) || %{})["injects"] || %{}

    Enum.reduce(injects["uses"] || [], {injects["imports"] || [], injects["aliases"] || %{}}, fn used,
                                                                                                 {imports, aliases} ->
      if MapSet.member?(seen, used) do
        {imports, aliases}
      else
        {i, a} = injects_of(used, index, MapSet.put(seen, used))
        {imports ++ i, Map.merge(a, aliases)}
      end
    end)
  end

  @doc "Split `Mod.fun/2` into `{module, name, arity}`; a bare `fun/2` has module nil; `*` stays a string."
  def split_qname(call) do
    {head, arity} =
      case String.split(call, "/") |> Enum.reverse() do
        [a | rest] when rest != [] -> {rest |> Enum.reverse() |> Enum.join("/"), parse_arity(a)}
        _ -> {call, "*"}
      end

    case String.split(head, ".") do
      [name] -> {nil, name, arity}
      parts -> {parts |> Enum.drop(-1) |> Enum.join("."), List.last(parts), arity}
    end
  end

  defp parse_arity("*"), do: "*"

  defp parse_arity(a) do
    case Integer.parse(a) do
      {n, ""} -> n
      _ -> "*"
    end
  end

  # === queries ===

  @doc "Exact callers of a qualified name: `[%{caller, call}]`, newest index first."
  def exact_callers(index, qn), do: Map.get(index.exact, qn, [])

  @doc "Fallback edges whose key could reach `qn`, excluding the definition's own clauses."
  def fallback_callers(index, qn) do
    {m, n, a} = split_qname(qn)

    Enum.filter(index.fallback, fn %{key: key, caller: caller} ->
      (key.module == nil or m in List.wrap(key.module)) and
        (key.name == "*" or key.name == n) and
        (key.arity == "*" or key.arity == a) and
        qn not in qualified_names(caller)
    end)
  end

  @doc """
  The definitions a user query names: `Mod.fun/2`, `Mod.fun`, `Suffix.Mod.fun`
  (module suffix), or a bare `fun` / `fun/2` (every module). Case-insensitive.
  """
  def targets(index, query) do
    query = String.trim(query)
    {mod, name, arity} = split_qname(if String.contains?(query, "/"), do: query, else: query <> "/*")
    mod_down = mod && String.downcase(mod)

    index.by_name
    |> Map.get(String.downcase(name), [])
    |> Enum.filter(fn qn ->
      {m, _n, a} = split_qname(qn)
      m_down = String.downcase(m)

      (arity == "*" or a == arity) and
        (mod_down == nil or m_down == mod_down or String.ends_with?(m_down, "." <> mod_down))
    end)
    |> Enum.sort()
  end

  @doc "Test/spec file?"
  def test_caller?(%{caller: %{entity: entity}}), do: EntityResolution.test_file?(entity["file_path"] || "")
end
