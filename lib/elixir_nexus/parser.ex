defmodule ElixirNexus.Parser do
  @moduledoc """
  Parses Elixir source files using Sourceror and extracts code entities.

  Every module (nested ones too) and every def/defp/defmacro/defdelegate in it
  becomes an entity. Each carries an `xref` map from `ElixirNexus.Parsers.ElixirXref`:
  functions their qualified names (`Mod.fun/arity`) and resolved calls, modules
  their imports, `use`s and what they inject. HEEx templates (`.heex`) are the
  function components `embed_templates` makes of them (`parse_template/1`).
  """
  require Logger

  alias ElixirNexus.CodeSchema
  alias ElixirNexus.Parsers.ElixirXref

  def parse_file(file_path) do
    with {:ok, source_code} <- File.read(file_path) do
      parse_source(file_path, source_code)
    else
      {:error, reason} ->
        Logger.error("Failed to read file #{file_path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def parse_source(file_path, source_code) do
    case Sourceror.parse_string(source_code) do
      {:ok, ast} ->
        entities = extract_entities(file_path, ast, source_code)
        {:ok, entities}

      {:error, reason} ->
        Logger.error("Parse error in #{file_path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Parse a `.heex` template as the function component Phoenix's `embed_templates`
  defines from it: `dir/page_html/home.html.heex` is `home/1` of the module in
  `dir/page_html.ex` that embeds `"page_html/*"`. Its calls are the template's
  components and expressions, resolved in that module's context. Without an
  embedding module it is a function of no module (calls stay bare).
  """
  def parse_template(file_path) do
    with {:ok, template} <- File.read(file_path) do
      name = file_path |> Path.basename() |> String.split(".") |> hd()
      {module, ctx} = embedding_module(file_path)

      entity = %CodeSchema{
        file_path: file_path,
        entity_type: :function,
        name: name,
        content: template,
        start_line: 1,
        end_line: template |> String.split("\n") |> length(),
        module_path: module,
        parameters: ["assigns"],
        visibility: :public,
        calls: [],
        is_a: [],
        contains: [],
        xref: %{
          "qualified_names" => if(module, do: ["#{module}.#{name}/1"], else: []),
          "calls" => ElixirXref.heex_calls(template, ctx),
          "callback" => false
        }
      }

      {:ok, [entity]}
    end
  end

  # Phoenix convention: templates in `x_html/` are embedded by `x_html.ex` next to the directory.
  defp embedding_module(file_path) do
    dir = Path.dirname(file_path)

    with {:ok, source} <- File.read(dir <> ".ex"),
         {:ok, ast} <- Sourceror.parse_string(source),
         {fqn, ctx} <- find_embedding_module(ast, Path.basename(dir)) do
      {fqn, ctx}
    else
      _ -> {nil, ElixirXref.empty_ctx()}
    end
  end

  defp find_embedding_module(ast, glob_dir) do
    ast
    |> top_level_forms()
    |> Enum.find_value(fn
      {:defmodule, _, [name_ast | rest]} ->
        fqn = ElixirXref.module_name(name_ast, nil)
        forms = module_body_forms(rest)
        if Enum.any?(forms, &embeds?(&1, glob_dir)), do: {fqn, ElixirXref.module_context(fqn, forms)}

      _ ->
        nil
    end)
  end

  defp embeds?(form, glob_dir) do
    with {:embed_templates, _, [pattern | _]} <- ElixirXref.unwrap(form),
         p when is_binary(p) <- ElixirXref.unwrap(pattern) do
      String.starts_with?(p, glob_dir <> "/")
    else
      _ -> false
    end
  end

  defp extract_entities(file_path, ast, source_code) do
    ast
    |> top_level_forms()
    |> Enum.filter(&is_code_entity/1)
    |> Enum.flat_map(&extract_form(&1, file_path, source_code, nil))
    |> Enum.reject(&is_nil/1)
  end

  defp top_level_forms({:__block__, _, forms}) when is_list(forms), do: forms
  defp top_level_forms(list) when is_list(list), do: list
  defp top_level_forms(node) when is_tuple(node), do: [node]
  defp top_level_forms(_), do: []

  defp extract_form({:defmodule, _, [name_ast | rest]} = node, file_path, source_code, parent_ctx) do
    fqn = ElixirXref.module_name(name_ast, parent_ctx)
    forms = module_body_forms(rest)
    ctx = ElixirXref.module_context(fqn, forms, parent_ctx)

    module_entity =
      case CodeSchema.from_ast(file_path, node, source_code) do
        nil -> nil
        entity -> %{entity | name: fqn, module_path: fqn, xref: ElixirXref.module_xref(ctx, forms)}
      end

    [module_entity | extract_module_members(forms, file_path, source_code, ctx)]
  end

  defp extract_form(node, file_path, source_code, _parent_ctx) do
    [CodeSchema.from_ast(file_path, node, source_code)]
  end

  defp module_body_forms([body_list]) when is_list(body_list) do
    Enum.flat_map(body_list, fn
      {{:__block__, _, [:do]}, {:__block__, _, children}} when is_list(children) ->
        Enum.map(children, fn
          {{:__block__, _, [:do]}, func} -> func
          func -> func
        end)

      {{:__block__, _, [:do]}, body} ->
        [body]

      _ ->
        []
    end)
  end

  defp module_body_forms(_), do: []

  # Functions, delegates and nested modules of one module body, in order, so a
  # preceding `@impl` marks the function after it (and all its clauses) as a callback.
  defp extract_module_members(forms, file_path, source_code, ctx) do
    {entities, _} =
      Enum.flat_map_reduce(forms, {false, MapSet.new()}, fn form, {impl_pending, callbacks} = acc ->
        case form do
          {:@, _, [{:impl, _, [value]}]} ->
            {[], {ElixirXref.unwrap(value) != false, callbacks}}

          {:defmodule, _, _} = nested ->
            {extract_form(nested, file_path, source_code, ctx), acc}

          {def_type, _, _} = def_node when def_type in [:def, :defp, :defmacro, :defdelegate] ->
            case {CodeSchema.from_ast(file_path, def_node, source_code), ElixirXref.signature(def_node)} do
              {nil, _} ->
                {[], acc}

              {entity, nil} ->
                {[entity], acc}

              {entity, {name, arities}} ->
                keys = Enum.map(arities, &{name, &1})
                callbacks = if impl_pending, do: Enum.into(keys, callbacks), else: callbacks
                callback? = Enum.any?(keys, &MapSet.member?(callbacks, &1))
                {[annotate(entity, def_node, name, arities, callback?, ctx)], {false, callbacks}}
            end

          _ ->
            {[], acc}
        end
      end)

    entities
  end

  defp annotate(entity, def_node, name, arities, callback?, ctx) do
    body = def_body(def_node)

    calls =
      case def_node do
        {:defdelegate, _, [_head, opts]} -> delegate_calls(opts, name, hd(arities), ctx)
        _ -> ElixirXref.calls(body, ctx)
      end

    xref = %{
      "qualified_names" => Enum.map(arities, &"#{ctx.module}.#{name}/#{&1}"),
      "calls" => calls,
      "callback" => callback?
    }

    xref =
      case ElixirXref.body_imports(body, ctx) do
        [] -> xref
        imports -> Map.put(xref, "imports", imports)
      end

    %{entity | module_path: ctx.module, xref: xref}
  end

  # The guard and the body; never the head (its params would read as calls).
  defp def_body({_type, _, [head | rest]}) do
    guard =
      case ElixirXref.unwrap(head) do
        {:when, _, [_ | guards]} -> guards
        _ -> []
      end

    guard ++ rest
  end

  # defdelegate fun(a, b), to: Mod, as: :other calls Mod.other/2.
  defp delegate_calls(opts, name, arity, ctx) do
    kw =
      case ElixirXref.unwrap(opts) do
        list when is_list(list) -> list
        _ -> []
      end

    get = fn key ->
      Enum.find_value(kw, fn
        {k, v} -> if ElixirXref.unwrap(k) == key, do: ElixirXref.unwrap(v)
        _ -> nil
      end)
    end

    target =
      case get.(:as) do
        as when is_atom(as) and not is_nil(as) -> Atom.to_string(as)
        _ -> name
      end

    case get.(:to) do
      {:__aliases__, _, _} = to -> ["#{ElixirXref.expand_alias(to, ctx)}.#{target}/#{arity}"]
      _ -> ["?#{target}/#{arity}"]
    end
  end

  defp is_code_entity({:defmodule, _, _}), do: true
  defp is_code_entity({:def, _, _}), do: true
  defp is_code_entity({:defmacro, _, _}), do: true
  defp is_code_entity({:defp, _, _}), do: true
  defp is_code_entity({:defstruct, _, _}), do: true
  defp is_code_entity(_), do: false
end
