defmodule ElixirNexus.Parsers.ElixirXref do
  @moduledoc """
  Resolves Elixir calls to `Module.fun/arity` at parse time, like `mix xref`
  does from compiled code, but from source (Sourceror AST or `Code.string_to_quoted`).

  A module's context (`module_context/3`) holds what the compiler would know
  lexically: the module name, its aliases (`alias A.{B, C}`, `as:`, `__MODULE__`,
  nested modules), its imports and `use`s, the functions it defines, and what
  its `quote` blocks inject into a module that `use`s it.

  `calls/2` returns one string per call:

    * `"Mod.fun/2"`: a remote call with the alias expanded, or a local call to a
      function the module defines. Exact.
    * `"fun/2"`: a bare call the module does not define. Resolved at query time
      against the module's imports and what its `use`s inject.
    * `"Mod.fun/*"`: a reference whose arity is unknown (`{Mod, :fun}`,
      `apply(Mod, :fun, args)`).
    * `"Mod.*/0"`: `apply(Mod, fun, [])` with a variable function.
    * `"?fun/2"`: a call on a variable module (`mod.fun(x)`, `apply(mod, :fun, ...)`).
      Only a short-name match can say where it goes.

  Arity is the number of arguments, plus one on the right side of `|>`.
  Calls to Kernel and Kernel.SpecialForms (`if`, `is_nil`, `def`) are dropped.
  """

  @special_forms Kernel.SpecialForms.__info__(:macros) |> Enum.map(fn {n, _} -> Atom.to_string(n) end) |> MapSet.new()

  @kernel (Kernel.__info__(:functions) ++ Kernel.__info__(:macros))
          |> Enum.map(fn {n, a} -> {Atom.to_string(n), a} end)
          |> MapSet.new()

  # Module attributes whose arguments are types or docs, not code.
  @non_code_attrs ~w(spec type typep opaque callback macrocallback doc moduledoc typedoc shortdoc impl behaviour
                     derive enforce_keys optional_callbacks deprecated dialyzer compile)a

  @def_forms [:def, :defp, :defmacro, :defmacrop, :defguard, :defguardp]

  @identifier ~r/^[a-z_][a-zA-Z0-9_]*[?!]?$/

  @type ctx :: %{
          module: String.t() | nil,
          aliases: %{optional(String.t()) => String.t()},
          imports: [String.t()],
          local: MapSet.t()
        }

  @doc "An empty context: top-level code outside any module."
  def empty_ctx, do: %{module: nil, aliases: %{}, imports: [], local: MapSet.new()}

  @doc """
  The lexical context of module `fqn` with top-level body `forms`, inheriting the
  enclosing module's aliases and imports when nested.
  """
  def module_context(fqn, forms, parent \\ nil) do
    parent = parent || empty_ctx()

    # A nested module is aliased by its first segment in the enclosing module, and
    # the nested module sees the same alias.
    parent_aliases =
      case parent.module do
        nil -> parent.aliases
        outer -> Map.put(parent.aliases, nested_alias_key(fqn, outer), nested_alias_target(fqn, outer))
      end

    base = %{module: fqn, aliases: parent_aliases, imports: parent.imports, local: MapSet.new()}

    ctx =
      Enum.reduce(forms, base, fn form, ctx ->
        case unwrap(form) do
          {:alias, _, _} = node -> %{ctx | aliases: Map.merge(ctx.aliases, alias_entries(node, ctx))}
          {:import, _, [target | _]} -> add_import(ctx, target)
          {:defmodule, _, [name | _]} -> add_nested_alias(ctx, name)
          _ -> ctx
        end
      end)

    %{ctx | local: local_defs(forms)}
  end

  @doc "The fully qualified name of a `defmodule` name AST inside `parent`."
  def module_name(name_ast, parent) do
    parent = parent || empty_ctx()

    case unwrap(name_ast) do
      {:__aliases__, _, parts} ->
        written = parts_to_string(parts, parent)

        case {parent.module, parts} do
          {nil, _} -> written
          {_, [{:__MODULE__, _, _} | _]} -> written
          {outer, _} -> outer <> "." <> Enum.map_join(parts, ".", &to_string/1)
        end

      atom when is_atom(atom) ->
        atom |> Atom.to_string() |> String.trim_leading("Elixir.")

      other ->
        Macro.to_string(other)
    end
  end

  @doc """
  The module entity's resolution data: module-level calls (outside any def),
  explicit imports and `use`s, behaviours, and what `quote` blocks inject.
  """
  def module_xref(ctx, forms) do
    {uses, use_calls} = uses(forms, ctx)

    top_calls =
      forms
      |> Enum.reject(&definition_form?/1)
      |> Enum.flat_map(&calls(&1, ctx))

    %{
      "module" => ctx.module,
      "calls" => Enum.uniq(use_calls ++ top_calls),
      "imports" => ctx.imports |> Enum.reject(&String.starts_with?(&1, "?")) |> Enum.uniq(),
      "dynamic_imports" => Enum.any?(ctx.imports, &String.starts_with?(&1, "?")),
      "uses" => uses,
      "behaviours" => behaviours(forms, ctx),
      "injects" => injects(forms, ctx)
    }
  end

  @doc """
  `{name, arities}` of a def/defp/defmacro/defdelegate node, or nil.
  Default arguments (`\\\\`) give one arity per optional argument.
  """
  def signature({form, _, [head | _]}) when form in @def_forms or form == :defdelegate do
    case unwrap(head) do
      {:when, _, [inner | _]} -> head_signature(inner)
      other -> head_signature(other)
    end
  end

  def signature(_), do: nil

  defp head_signature({name, _, args}) when is_atom(name) do
    args = if is_list(args), do: args, else: []
    defaults = Enum.count(args, &match?({:\\, _, _}, unwrap(&1)))
    total = length(args)
    {Atom.to_string(name), Enum.to_list((total - defaults)..total)}
  end

  defp head_signature(_), do: nil

  @doc "The calls inside `ast` (a function body, a module-level form, a template expression)."
  def calls(ast, ctx) do
    ctx = with_body_aliases(ast, ctx)

    ast
    |> walk(ctx, [])
    |> Enum.reverse()
    |> Enum.uniq()
  end

  @doc "Imports declared inside a function body (lexically scoped to it)."
  def body_imports(ast, ctx) do
    {_, imports} =
      Macro.prewalk(ast, [], fn
        {:import, _, [target | _]} = node, acc -> {node, acc ++ add_import(%{ctx | imports: []}, target).imports}
        {:quote, _, _}, acc -> {:ok, acc}
        node, acc -> {node, acc}
      end)

    imports |> Enum.reject(&String.starts_with?(&1, "?")) |> Enum.uniq()
  end

  @doc """
  Calls in a HEEx template: `<.name` and `<Mod.name` components (arity 1, the
  assigns) and the Elixir inside `{...}` and `<%= ... %>`.
  """
  def heex_calls(template, ctx) when is_binary(template) do
    local =
      ~r/<\.([a-z_][a-zA-Z0-9_]*[?!]?)/
      |> Regex.scan(template, capture: :all_but_first)
      |> Enum.map(fn [name] -> local_ref(name, 1, ctx) end)

    remote =
      ~r/<((?:[A-Z][a-zA-Z0-9_]*\.)+)([a-z_][a-zA-Z0-9_]*[?!]?)/
      |> Regex.scan(template, capture: :all_but_first)
      |> Enum.map(fn [mod, name] ->
        "#{mod |> String.trim_trailing(".") |> expand_string_alias(ctx)}.#{name}/1"
      end)

    expressions =
      template
      |> template_expressions()
      |> Enum.flat_map(fn expr ->
        case Code.string_to_quoted(expr) do
          {:ok, ast} -> walk(ast, ctx, []) |> Enum.reverse()
          _ -> []
        end
      end)

    Enum.uniq(local ++ remote ++ expressions)
  end

  # === walking ===

  defp walk({:__block__, _, [single]}, ctx, acc) when not is_list(single), do: walk_literal(single, ctx, acc)

  defp walk({:|>, _, [left, right]}, ctx, acc) do
    acc = walk(left, ctx, acc)
    walk_call(right, ctx, acc, 1)
  end

  # &Mod.fun/2 and &fun/2
  defp walk({:&, _, [{:/, _, [ref, arity_ast]}]} = node, ctx, acc) do
    arity = literal(arity_ast)

    case {unwrap(ref), arity} do
      {{name, _, context}, n} when is_atom(name) and is_atom(context) and is_integer(n) ->
        add(acc, local_ref(Atom.to_string(name), n, ctx))

      {{{:., _, [recv, name]}, _, []}, n} when is_atom(name) and is_integer(n) ->
        add(acc, remote_ref(recv, Atom.to_string(name), n, ctx))

      _ ->
        walk_children(node, ctx, acc)
    end
  end

  defp walk({:@, _, [{attr, _, args}]}, ctx, acc) when is_atom(attr) do
    if attr in @non_code_attrs or not is_list(args), do: acc, else: walk_args(args, ctx, acc)
  end

  # `use Mod, opts`: the options are code (`annotations: Tool.annotations(...)`).
  defp walk({:use, _, [_target | opts]}, ctx, acc), do: walk_args(opts, ctx, acc)
  defp walk({form, _, _}, _ctx, acc) when form in [:alias, :import, :require, :use, :defmodule], do: acc

  # Kernel.apply/3 and apply/3
  defp walk({:apply, _, [m, f, a]}, ctx, acc), do: walk_apply(m, f, a, ctx, acc)

  defp walk({{:., _, [{:__aliases__, _, [:Kernel]}, :apply]}, _, [m, f, a]}, ctx, acc),
    do: walk_apply(m, f, a, ctx, acc)

  # {Mod, :fun, args}: a function named by reference. Whoever calls it may add
  # arguments (Plug's body_reader prepends conn and opts), so any arity.
  defp walk({:{}, _, [m, f, _a]} = node, ctx, acc) do
    acc = walk_children(node, ctx, acc)

    with mod when is_binary(mod) <- module_of(m, ctx),
         name when is_binary(name) <- function_atom(f) do
      add(acc, "#{mod}.#{name}/*")
    else
      _ -> acc
    end
  end

  # plug :name is a function plug: name/2 of this module or an imported one.
  # plug Mod is a module plug: Mod.init/1 and Mod.call/2.
  defp walk({:plug, _, [target | rest]}, ctx, acc) do
    acc =
      case unwrap(target) do
        name when is_atom(name) and not is_nil(name) and not is_boolean(name) ->
          add(acc, local_ref(Atom.to_string(name), 2, ctx))

        {:__aliases__, _, _} = a ->
          mod = alias_to_string(a, ctx)
          acc |> add("#{mod}.init/1") |> add("#{mod}.call/2")

        _ ->
          acc
      end

    walk_args(rest, ctx, acc)
  end

  defp walk({:sigil_H, _, [{:<<>>, _, parts} | _]}, ctx, acc) do
    template = parts |> Enum.filter(&is_binary/1) |> Enum.join()
    template |> heex_calls(ctx) |> Enum.reduce(acc, &add(&2, &1))
  end

  defp walk({_, _, args} = node, ctx, acc) when is_list(args), do: walk_call(node, ctx, acc, 0)

  defp walk({left, right}, ctx, acc) do
    acc = walk_mfa_pair(left, right, ctx, acc)

    # on_mount: [Mod, {Mod, :name}] in live_session options
    acc = if unwrap(left) == :on_mount, do: Enum.reduce(on_mount_refs(right, ctx), acc, &add(&2, &1)), else: acc
    acc = walk(left, ctx, acc)
    walk(right, ctx, acc)
  end

  # A literal list. A bare module in it, or `{Mod, arg}`, is a supervisor child
  # spec: the supervisor calls Mod.child_spec/1.
  defp walk(list, ctx, acc) when is_list(list) do
    Enum.reduce(list, acc, fn element, acc ->
      acc = add(acc, child_spec_ref(element, ctx))
      walk(element, ctx, acc)
    end)
  end

  defp walk(_other, _ctx, acc), do: acc

  # A call's argument list (not a literal list).
  defp walk_args(args, ctx, acc) when is_list(args), do: Enum.reduce(args, acc, &walk(&1, ctx, &2))
  defp walk_args(other, ctx, acc), do: walk(other, ctx, acc)

  defp child_spec_ref(element, ctx) do
    case unwrap(element) do
      {:__aliases__, _, _} = a ->
        "#{alias_to_string(a, ctx)}.child_spec/1"

      {left, right} ->
        with mod when is_binary(mod) <- module_of(left, ctx),
             nil <- function_atom(right) do
          "#{mod}.child_spec/1"
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp on_mount_refs(target, ctx) do
    case unwrap(target) do
      list when is_list(list) ->
        Enum.flat_map(list, &on_mount_refs(&1, ctx))

      {left, _arg} ->
        case module_of(left, ctx) do
          nil -> []
          mod -> ["#{mod}.on_mount/4"]
        end

      other ->
        case module_of(other, ctx) do
          nil -> []
          mod -> ["#{mod}.on_mount/4"]
        end
    end
  end

  # The module an expression names: an alias or __MODULE__; nil otherwise.
  defp module_of(ast, ctx) do
    case unwrap(ast) do
      {:__aliases__, _, _} = a -> alias_to_string(a, ctx)
      {:__MODULE__, _, _} -> ctx.module
      _ -> nil
    end
  end

  # The function name a literal atom could be; nil for nil, booleans and non-identifiers.
  defp function_atom(ast) do
    with name when is_atom(name) and not is_nil(name) and not is_boolean(name) <- literal(ast),
         string = Atom.to_string(name),
         true <- Regex.match?(@identifier, string) do
      string
    else
      _ -> nil
    end
  end

  # Erlang-style MFA arguments, `(..., Mod, :fun, [args], ...)`, as in :erpc.call,
  # spawn/3, :timer.apply_after/4: a call to Mod.fun with that many arguments.
  defp mfa_args(args, ctx, acc) do
    args
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.reduce(acc, fn [m, f, a], acc ->
      with mod when is_binary(mod) <- module_of(m, ctx),
           name when is_binary(name) <- function_atom(f) do
        arity =
          case literal(a) do
            list when is_list(list) -> Integer.to_string(length(list))
            _ -> "*"
          end

        add(acc, "#{mod}.#{name}/#{arity}")
      else
        _ -> acc
      end
    end)
  end

  # Sourceror wraps literals ({:__block__, _, [:atom]}, 2-tuples, lists).
  defp walk_literal({left, right}, ctx, acc), do: walk({left, right}, ctx, acc)
  defp walk_literal(other, ctx, acc), do: walk(other, ctx, acc)

  # {Mod, :fun}: arity unknown.
  defp walk_mfa_pair(left, right, ctx, acc) do
    with mod when is_binary(mod) <- module_of(left, ctx),
         name when is_binary(name) <- function_atom(right) do
      add(acc, "#{mod}.#{name}/*")
    else
      _ -> acc
    end
  end

  defp walk_apply(m, f, a, ctx, acc) do
    arity =
      case literal(a) do
        list when is_list(list) -> Integer.to_string(length(list))
        _ -> "*"
      end

    ref =
      case {unwrap(m), literal(f)} do
        {{:__aliases__, _, _} = alias_ast, name} when is_atom(name) and not is_nil(name) ->
          "#{alias_to_string(alias_ast, ctx)}.#{name}/#{arity}"

        {{:__MODULE__, _, _}, name} when is_atom(name) and not is_nil(name) and ctx.module != nil ->
          "#{ctx.module}.#{name}/#{arity}"

        {{:__aliases__, _, _} = alias_ast, _} ->
          "#{alias_to_string(alias_ast, ctx)}.*/#{arity}"

        {{:__MODULE__, _, _}, _} when ctx.module != nil ->
          "#{ctx.module}.*/#{arity}"

        {_, name} when is_atom(name) and not is_nil(name) ->
          "?#{name}/#{arity}"

        _ ->
          nil
      end

    acc = add(acc, ref)
    walk_args([m, f, a], ctx, acc)
  end

  defp walk_call({:__block__, _, [single]}, ctx, acc, extra) when not is_list(single),
    do: walk_call(single, ctx, acc, extra)

  # Remote call: Mod.fun(args), mod.fun(args), :erlang.fun(args)
  defp walk_call({{:., _, [recv, name]}, meta, args}, ctx, acc, extra)
       when is_atom(name) and is_list(args) do
    arity = length(args) + extra
    fname = Atom.to_string(name)

    ref =
      case unwrap(recv) do
        {:__aliases__, _, _} ->
          remote_ref(recv, fname, arity, ctx)

        {:__MODULE__, _, _} when ctx.module != nil ->
          "#{ctx.module}.#{fname}/#{arity}"

        # Erlang module (:ets.insert) — never a project function.
        atom when is_atom(atom) ->
          nil

        {var, _, context} when is_atom(var) and is_atom(context) ->
          # `map.field` parses as a paren-less call; it is a field access.
          if Keyword.get(meta, :no_parens, false), do: nil, else: "?#{fname}/#{arity}"

        _ ->
          if Keyword.get(meta, :no_parens, false), do: nil, else: "?#{fname}/#{arity}"
      end

    acc = add(acc, ref)
    acc = walk(recv, ctx, acc)
    acc = mfa_args(args, ctx, acc)
    walk_args(args, ctx, acc)
  end

  defp walk_call({name, _, args}, ctx, acc, extra) when is_atom(name) and is_list(args) do
    sname = Atom.to_string(name)

    if Regex.match?(@identifier, sname) and not String.starts_with?(sname, "__") do
      acc =
        acc
        |> add(local_ref(sname, length(args) + extra, ctx))
        |> add(render_ref(name, args, extra, ctx))
        |> then(
          &if(name == :on_mount, do: Enum.reduce(on_mount_refs(args, ctx), &1, fn r, a -> add(a, r) end), else: &1)
        )

      acc = mfa_args(args, ctx, acc)
      walk_args(args, ctx, acc)
    else
      walk_args(args, ctx, acc)
    end
  end

  # Anonymous function call f.(x), or anything else: just walk it.
  defp walk_call(node, ctx, acc, _extra), do: walk_children(node, ctx, acc)

  # render(conn, :template, ...) or conn |> render(:template, ...) in a Phoenix
  # controller renders the template function FooHTML.template/1.
  defp render_ref(:render, args, extra, ctx) do
    with template when not is_nil(template) <- Enum.at(args, 1 - extra),
         name when is_binary(name) <- function_atom(template),
         mod when is_binary(mod) <- ctx.module,
         true <- String.ends_with?(mod, "Controller") do
      "#{String.replace_suffix(mod, "Controller", "HTML")}.#{name}/1"
    else
      _ -> nil
    end
  end

  defp render_ref(_name, _args, _extra, _ctx), do: nil

  defp walk_children({_, _, args}, ctx, acc) when is_list(args), do: walk_args(args, ctx, acc)
  defp walk_children(_, _ctx, acc), do: acc

  defp add(acc, nil), do: acc
  defp add(acc, ref), do: [ref | acc]

  @doc false
  def local_ref(name, arity, ctx) do
    cond do
      ctx.module != nil and MapSet.member?(ctx.local, {name, arity}) -> "#{ctx.module}.#{name}/#{arity}"
      MapSet.member?(@special_forms, name) or name == "when" -> nil
      MapSet.member?(@kernel, {name, arity}) -> nil
      true -> "#{name}/#{arity}"
    end
  end

  defp remote_ref(recv, fname, arity, ctx) do
    case unwrap(recv) do
      {:__aliases__, _, _} = a -> "#{alias_to_string(a, ctx)}.#{fname}/#{arity}"
      {:__MODULE__, _, _} when ctx.module != nil -> "#{ctx.module}.#{fname}/#{arity}"
      _ -> "?#{fname}/#{arity}"
    end
  end

  # === context helpers ===

  defp with_body_aliases(ast, ctx) do
    {_, aliases} =
      Macro.prewalk(ast, ctx.aliases, fn
        {:alias, _, _} = node, acc -> {node, Map.merge(acc, alias_entries(node, %{ctx | aliases: acc}))}
        {:quote, _, _}, acc -> {:ok, acc}
        node, acc -> {node, acc}
      end)

    %{ctx | aliases: aliases}
  end

  defp alias_entries({:alias, _, [target | opts]}, ctx) do
    as =
      case opts do
        [kw] -> keyword_value(kw, :as)
        _ -> nil
      end

    case unwrap(target) do
      # alias A.{B, C.D}
      {{:., _, [base, :{}]}, _, children} ->
        base_name = alias_to_string(base, ctx)

        Map.new(children, fn child ->
          {:__aliases__, _, parts} = unwrap(child)
          {parts |> List.last() |> to_string(), base_name <> "." <> Enum.map_join(parts, ".", &to_string/1)}
        end)

      {:__aliases__, _, _} = a ->
        full = alias_to_string(a, ctx)

        key =
          case unwrap(as) do
            {:__aliases__, _, as_parts} -> Enum.map_join(as_parts, ".", &to_string/1)
            _ -> full |> String.split(".") |> List.last()
          end

        %{key => full}

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  end

  defp alias_entries(_, _ctx), do: %{}

  defp add_import(ctx, target) do
    case unwrap(target) do
      {:__aliases__, _, _} = a -> %{ctx | imports: ctx.imports ++ [alias_to_string(a, ctx)]}
      # import :lists — Erlang, never a project module.
      atom when is_atom(atom) -> ctx
      _ -> %{ctx | imports: ctx.imports ++ ["?dynamic"]}
    end
  end

  defp add_nested_alias(ctx, name_ast) do
    case unwrap(name_ast) do
      {:__aliases__, _, [first | _] = parts} when is_atom(first) and ctx.module != nil ->
        fqn = ctx.module <> "." <> Enum.map_join(parts, ".", &to_string/1)
        %{ctx | aliases: Map.put(ctx.aliases, nested_alias_key(fqn, ctx.module), nested_alias_target(fqn, ctx.module))}

      _ ->
        ctx
    end
  end

  defp nested_alias_key(fqn, outer), do: fqn |> String.replace_prefix(outer <> ".", "") |> String.split(".") |> hd()
  defp nested_alias_target(fqn, outer), do: outer <> "." <> nested_alias_key(fqn, outer)

  defp local_defs(forms) do
    forms
    |> Enum.flat_map(fn form ->
      case signature(unwrap(form)) do
        {name, arities} -> Enum.map(arities, &{name, &1})
        nil -> []
      end
    end)
    |> MapSet.new()
  end

  defp definition_form?(form) do
    case unwrap(form) do
      {f, _, _} when f in @def_forms or f in [:defmodule, :defdelegate] -> true
      _ -> false
    end
  end

  defp uses(forms, ctx) do
    forms
    |> Enum.flat_map(fn form ->
      case unwrap(form) do
        {:use, _, [target | opts]} ->
          case unwrap(target) do
            {:__aliases__, _, _} = a ->
              mod = alias_to_string(a, ctx)

              which =
                case opts do
                  [opt | _] ->
                    case literal(opt) do
                      atom when is_atom(atom) and not is_nil(atom) and not is_boolean(atom) -> ["#{mod}.#{atom}/0"]
                      _ -> []
                    end

                  [] ->
                    []
                end

              [{mod, which}]

            _ ->
              []
          end

        _ ->
          []
      end
    end)
    |> then(fn pairs -> {pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq(), Enum.flat_map(pairs, &elem(&1, 1))} end)
  end

  defp behaviours(forms, ctx) do
    Enum.flat_map(forms, fn form ->
      case unwrap(form) do
        {:@, _, [{:behaviour, _, [target]}]} ->
          case unwrap(target) do
            {:__aliases__, _, _} = a -> [alias_to_string(a, ctx)]
            _ -> []
          end

        _ ->
          []
      end
    end)
  end

  # What `use ThisModule` injects: the imports, aliases and uses inside any
  # `quote` in the module, expanded where the quote is written (alias hygiene).
  defp injects(forms, ctx) do
    {_, quotes} =
      Macro.prewalk(forms, [], fn
        {:quote, _, args} = node, acc -> {node, [args | acc]}
        node, acc -> {node, acc}
      end)

    {imports, aliases, uses} =
      quotes
      |> Enum.reverse()
      |> Enum.reduce({[], %{}, []}, fn body, {imports, aliases, uses} ->
        {_, found} =
          Macro.prewalk(body, {imports, aliases, uses}, fn
            {:import, _, [target | _]} = node, {i, a, u} ->
              {node, {i ++ add_import(%{ctx | imports: []}, target).imports, a, u}}

            {:alias, _, _} = node, {i, a, u} ->
              {node, {i, Map.merge(a, alias_entries(node, ctx)), u}}

            {:use, _, [target | _]} = node, {i, a, u} ->
              case unwrap(target) do
                {:__aliases__, _, _} = al -> {node, {i, a, u ++ [alias_to_string(al, ctx)]}}
                _ -> {node, {i, a, u}}
              end

            node, acc ->
              {node, acc}
          end)

        found
      end)

    %{
      "imports" => imports |> Enum.reject(&String.starts_with?(&1, "?")) |> Enum.uniq(),
      "aliases" => aliases,
      "uses" => Enum.uniq(uses)
    }
  end

  @doc "The full module name an `__aliases__` AST names in `ctx`."
  def expand_alias(alias_ast, ctx), do: alias_to_string(alias_ast, ctx)

  defp alias_to_string({:__aliases__, _, parts}, ctx), do: parts_to_string(parts, ctx)
  defp alias_to_string(other, ctx), do: alias_to_string(unwrap(other), ctx)

  defp parts_to_string([{:__MODULE__, _, _} | rest], ctx) do
    Enum.join([ctx.module || "__MODULE__" | Enum.map(rest, &to_string/1)], ".")
  end

  defp parts_to_string([first | rest], ctx) when is_atom(first) do
    expand_string_alias(Enum.join([first | rest], "."), ctx)
  end

  defp parts_to_string(parts, _ctx), do: Enum.map_join(parts, ".", &Macro.to_string/1)

  # "Layouts.app" with alias Layouts -> MyWeb.Layouts gives "MyWeb.Layouts.app".
  # Only the first segment is an alias; `Elixir.` is the root, not an alias.
  defp expand_string_alias("Elixir." <> rest, _ctx), do: rest

  defp expand_string_alias(name, ctx) do
    [first | rest] = String.split(name, ".")
    Enum.join([Map.get(ctx.aliases, first, first) | rest], ".")
  end

  defp keyword_value(kw, key) do
    case unwrap(kw) do
      list when is_list(list) ->
        Enum.find_value(list, fn
          {k, v} -> if unwrap(k) == key, do: v
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  @doc false
  def unwrap({:__block__, _, [single]}) when not is_list(single) or single == [], do: single
  def unwrap({:__block__, _, [list]}) when is_list(list), do: list
  def unwrap(other), do: other

  # A value that is not a literal; a tuple so no is_atom/is_list guard accepts it.
  @not_literal {:not_literal}

  defp literal(ast) do
    case unwrap(ast) do
      list when is_list(list) -> list
      {_, _, _} -> @not_literal
      other -> other
    end
  end

  # The Elixir expressions in a HEEx template: `{...}` (balanced, outside
  # strings) and `<%= ... %>` / `<% ... %>`.
  defp template_expressions(template) do
    eex = ~r/<%=?(.*?)%>/s |> Regex.scan(template, capture: :all_but_first) |> Enum.map(fn [e] -> e end)
    without_eex = Regex.replace(~r/<%.*?%>/s, template, "")
    eex ++ braces(without_eex, 0, [], [], nil)
  end

  defp braces(<<>>, _depth, _cur, acc, _quote), do: Enum.reverse(acc)

  defp braces(<<"{", rest::binary>>, 0, _cur, acc, nil), do: braces(rest, 1, [], acc, nil)

  defp braces(<<"{", rest::binary>>, depth, cur, acc, nil) when depth > 0,
    do: braces(rest, depth + 1, ["{" | cur], acc, nil)

  defp braces(<<"}", rest::binary>>, 1, cur, acc, nil),
    do: braces(rest, 0, [], [cur |> Enum.reverse() |> IO.iodata_to_binary() | acc], nil)

  defp braces(<<"}", rest::binary>>, depth, cur, acc, nil) when depth > 1,
    do: braces(rest, depth - 1, ["}" | cur], acc, nil)

  defp braces(<<"\\", c::utf8, rest::binary>>, depth, cur, acc, q) when depth > 0,
    do: braces(rest, depth, [<<c::utf8>>, "\\" | cur], acc, q)

  defp braces(<<"\"", rest::binary>>, depth, cur, acc, nil) when depth > 0,
    do: braces(rest, depth, ["\"" | cur], acc, "\"")

  defp braces(<<"\"", rest::binary>>, depth, cur, acc, "\""), do: braces(rest, depth, ["\"" | cur], acc, nil)

  defp braces(<<c::utf8, rest::binary>>, depth, cur, acc, q) when depth > 0,
    do: braces(rest, depth, [<<c::utf8>> | cur], acc, q)

  defp braces(<<_::utf8, rest::binary>>, 0, cur, acc, nil), do: braces(rest, 0, cur, acc, nil)
  defp braces(<<_, rest::binary>>, depth, cur, acc, q), do: braces(rest, depth, cur, acc, q)
end
