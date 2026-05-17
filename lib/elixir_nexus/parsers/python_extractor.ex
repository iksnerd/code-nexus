defmodule ElixirNexus.Parsers.PythonExtractor do
  @moduledoc """
  Entity extractor for Python ASTs from tree-sitter.
  Extracts functions, classes, methods, decorators, and imports.
  """

  alias ElixirNexus.CodeSchema

  @doc "Extract code entities from a tree-sitter AST."
  def extract_entities(file_path, ast, source) do
    {qual_table, module_paths} = analyze_imports(ast, source)

    declarations =
      ast
      |> walk_ast(nil, [])
      |> Enum.map(&to_code_schema(file_path, &1, source, qual_table))
      |> Enum.reject(&is_nil/1)

    # Enrich declarations with import module paths
    declarations =
      Enum.map(declarations, fn entity ->
        %{entity | is_a: Enum.uniq(entity.is_a ++ module_paths)}
      end)

    # Attribute from-imported symbols to the functions that use them.
    # The NIF's depth limits can prevent deeply nested calls (e.g. inside
    # try/for blocks) from appearing in the AST. We supplement by checking
    # each function's source content for bare symbol names and adding the
    # qualified call (module.symbol) when found.
    declarations = enrich_calls_from_import_table(declarations, qual_table)

    # Create a file-level module entity if there are any imports
    file_entity =
      if module_paths != [] do
        # Qualified calls: "module_path.symbol" for every from-import
        imported_calls =
          qual_table
          |> Enum.map(fn {sym, mod} -> "#{mod}.#{sym}" end)
          |> Enum.uniq()

        [
          %CodeSchema{
            file_path: file_path,
            entity_type: :module,
            name: Path.basename(file_path, Path.extname(file_path)),
            content: "",
            start_line: 1,
            end_line: 1,
            parameters: [],
            visibility: :public,
            calls: imported_calls,
            is_a: module_paths,
            contains: declarations |> Enum.map(& &1.name) |> Enum.reject(&is_nil/1),
            language: :python
          }
        ]
      else
        []
      end

    file_entity ++ declarations
  end

  defp walk_ast(%{"kind" => kind, "children" => children} = node, parent_class, acc) do
    acc =
      case kind do
        "function_definition" ->
          [{node, parent_class} | acc]

        "class_definition" ->
          [{node, nil} | acc]

        _ ->
          acc
      end

    # Track class context for methods
    new_parent = if kind == "class_definition", do: node["name"], else: parent_class

    Enum.reduce(children, acc, &walk_ast(&1, new_parent, &2))
  end

  defp walk_ast(%{"kind" => kind} = node, parent_class, acc) do
    case kind do
      "function_definition" -> [{node, parent_class} | acc]
      "class_definition" -> [{node, nil} | acc]
      _ -> acc
    end
  end

  defp walk_ast(_, _, acc), do: acc

  defp to_code_schema(file_path, {node, parent_class}, source, import_table) do
    kind = node["kind"]
    name = node["name"]
    start_line = (node["start_row"] || 0) + 1
    end_line = (node["end_row"] || 0) + 1

    {entity_type, visibility} =
      case kind do
        "function_definition" ->
          if parent_class do
            # Method inside a class
            vis = if String.starts_with?(name || "", "_"), do: :private, else: :public
            {:method, vis}
          else
            vis = if String.starts_with?(name || "", "_"), do: :private, else: :public
            {:function, vis}
          end

        "class_definition" ->
          {:class, :public}

        _ ->
          {:function, nil}
      end

    full_name =
      if parent_class && entity_type == :method do
        "#{parent_class}.#{name}"
      else
        name
      end

    decorators = extract_decorators(node)

    if full_name do
      %CodeSchema{
        file_path: file_path,
        entity_type: entity_type,
        name: full_name,
        content: extract_content(source, start_line, end_line),
        start_line: start_line,
        end_line: end_line,
        module_path: parent_class,
        parameters: extract_params(node),
        visibility: visibility,
        calls: extract_calls(node, import_table),
        is_a: extract_bases(node) ++ decorators,
        contains: extract_contains(node),
        language: :python
      }
    end
  end

  defp extract_content(source, start_line, end_line) when start_line > 0 and end_line > 0 do
    source
    |> String.split("\n")
    |> Enum.slice((start_line - 1)..(end_line - 1))
    |> Enum.join("\n")
  end

  defp extract_content(_, _, _), do: ""

  defp extract_params(%{"children" => children}) do
    children
    |> Enum.filter(&(&1["kind"] == "parameters"))
    |> Enum.flat_map(fn params ->
      (params["children"] || [])
      |> Enum.filter(&(&1["kind"] in ["identifier", "default_parameter", "typed_parameter"]))
      |> Enum.map(&(&1["name"] || &1["text"] || ""))
      |> Enum.reject(&(&1 == "self"))
    end)
  end

  defp extract_params(_), do: []

  defp extract_calls(node, import_table) do
    node
    |> do_extract_calls()
    |> Enum.map(fn call ->
      case Map.get(import_table, call) do
        nil -> call
        mod -> "#{mod}.#{call}"
      end
    end)
    |> Enum.uniq()
  end

  defp do_extract_calls(%{"children" => children}) do
    Enum.flat_map(children, &find_calls/1)
  end

  defp do_extract_calls(_), do: []

  defp find_calls(%{"kind" => "call", "name" => name}) when is_binary(name), do: [name]

  defp find_calls(%{"kind" => "call", "children" => children}) do
    children
    |> Enum.filter(&(&1["kind"] in ["identifier", "attribute"]))
    |> Enum.map(&(&1["text"] || &1["name"] || ""))
  end

  defp find_calls(%{"children" => children}), do: Enum.flat_map(children, &find_calls/1)
  defp find_calls(_), do: []

  defp extract_bases(%{"kind" => "class_definition", "children" => children}) do
    children
    |> Enum.filter(&(&1["kind"] == "argument_list"))
    |> Enum.flat_map(fn args ->
      (args["children"] || [])
      |> Enum.filter(&(&1["kind"] == "identifier"))
      |> Enum.map(&(&1["text"] || ""))
    end)
  end

  defp extract_bases(_), do: []

  defp extract_contains(%{"kind" => "class_definition", "children" => children}) do
    # Methods may be direct children or nested inside a "block" node
    children
    |> Enum.flat_map(fn
      %{"kind" => "block", "children" => block_children} ->
        Enum.filter(block_children, &(&1["kind"] == "function_definition"))

      %{"kind" => "function_definition"} = node ->
        [node]

      _ ->
        []
    end)
    |> Enum.map(&(&1["name"] || ""))
    |> Enum.reject(&(&1 == ""))
  end

  defp extract_contains(_), do: []

  # --- Decorator extraction ---

  @doc false
  def extract_decorators(%{"children" => children}) do
    children
    |> Enum.filter(&(&1["kind"] == "decorator"))
    |> Enum.map(&extract_decorator_name/1)
    |> Enum.reject(&is_nil/1)
  end

  def extract_decorators(_), do: []

  defp extract_decorator_name(%{"children" => children}) do
    children
    |> Enum.find(&(&1["kind"] in ["identifier", "attribute", "call"]))
    |> case do
      %{"kind" => "identifier", "text" => text} when is_binary(text) ->
        "@#{text}"

      %{"kind" => "identifier", "name" => name} when is_binary(name) ->
        "@#{name}"

      %{"kind" => "attribute", "text" => text} when is_binary(text) ->
        "@#{text}"

      %{"kind" => "call", "children" => call_children} ->
        call_children
        |> Enum.find(&(&1["kind"] in ["identifier", "attribute"]))
        |> case do
          %{"text" => text} when is_binary(text) -> "@#{text}"
          %{"name" => name} when is_binary(name) -> "@#{name}"
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp extract_decorator_name(_), do: nil

  # --- Import analysis (source-text based) ---

  # Returns {qual_table, module_paths}:
  #   qual_table:   %{local_name => "module.path"} for from-imports
  #   module_paths: unique list of all imported module paths (for is_a edges)
  defp analyze_imports(ast, source) do
    source_lines = String.split(source, "\n")

    ast
    |> find_nodes(["import_from_statement", "import_statement"])
    |> Enum.reduce({%{}, []}, fn node, {table, paths} ->
      case node["kind"] do
        "import_from_statement" ->
          mod = extract_module_path_from_source(node, source_lines)

          if mod do
            syms = extract_import_symbols(node, mod)

            # Fallback: parenthesized multi-line imports produce an import_list
            # node that the NIF filters out, so AST-based extraction returns [].
            # Read the raw source lines to recover the symbol names.
            syms =
              if syms == [],
                do: extract_import_symbols_from_source(node, source_lines, mod),
                else: syms

            new_table = Enum.reduce(syms, table, &Map.put(&2, &1, mod))
            {new_table, [mod | paths]}
          else
            {table, paths}
          end

        "import_statement" ->
          mod = extract_import_source(node)
          if mod, do: {table, [mod | paths]}, else: {table, paths}
      end
    end)
    |> then(fn {table, paths} -> {table, Enum.uniq(paths)} end)
  end

  # Read the module path from the source line (handles dotted paths that the NIF filters out).
  defp extract_module_path_from_source(node, source_lines) do
    row = node["start_row"] || 0
    line = Enum.at(source_lines, row, "")

    case Regex.run(~r/^\s*from\s+([\w.]+)\s+import/, line) do
      [_, module_path] -> module_path
      _ -> nil
    end
  end

  # Fallback for parenthesized multi-line imports whose import_list node is filtered
  # by the NIF. Reads raw source lines from start_row until the closing ')' and
  # extracts identifier tokens from the captured text.
  defp extract_import_symbols_from_source(node, source_lines, module_path) do
    start_row = node["start_row"] || 0
    first_line = Enum.at(source_lines, start_row, "")

    if String.contains?(first_line, "(") do
      block =
        source_lines
        |> Enum.slice(start_row, 30)
        |> Enum.reduce_while([], fn line, acc ->
          acc = [line | acc]
          if String.contains?(line, ")"), do: {:halt, acc}, else: {:cont, acc}
        end)
        |> Enum.reverse()
        |> Enum.join(" ")

      case Regex.run(~r/import\s*\(([^)]*)\)/, block) do
        [_, inner] ->
          inner
          |> String.replace(~r/#[^\n]*/, "")
          |> String.split(~r/[\s,]+/)
          |> Enum.reject(&(&1 == "" or &1 == module_path))

        _ ->
          []
      end
    else
      []
    end
  end

  defp enrich_calls_from_import_table(entities, qual_table) when map_size(qual_table) == 0,
    do: entities

  defp enrich_calls_from_import_table(entities, qual_table) do
    Enum.map(entities, fn entity ->
      if entity.entity_type in [:function, :method] and is_binary(entity.content) and
           entity.content != "" do
        existing = MapSet.new(entity.calls)

        extra =
          Enum.flat_map(qual_table, fn {sym, mod} ->
            qualified = "#{mod}.#{sym}"

            if not MapSet.member?(existing, qualified) and
                 Regex.match?(~r/\b#{Regex.escape(sym)}\b/, entity.content) do
              [qualified]
            else
              []
            end
          end)

        if extra == [], do: entity, else: %{entity | calls: entity.calls ++ extra}
      else
        entity
      end
    end)
  end

  # Extract the locally-bound symbol names from an import_from_statement node,
  # excluding the module name itself (for bare-identifier imports like `from os import getcwd`).
  defp extract_import_symbols(node, module_path) do
    (node["children"] || [])
    |> Enum.filter(&(&1["kind"] in ["identifier", "import_list", "aliased_import"]))
    |> Enum.flat_map(fn
      %{"kind" => "identifier", "text" => t} when is_binary(t) and t != "" ->
        [t]

      %{"kind" => "identifier", "name" => n} when is_binary(n) and n != "" ->
        [n]

      %{"kind" => "import_list", "children" => kids} ->
        Enum.flat_map(kids, fn
          %{"kind" => "identifier", "text" => t} when is_binary(t) and t != "" -> [t]
          %{"kind" => "identifier", "name" => n} when is_binary(n) and n != "" -> [n]
          %{"kind" => "aliased_import", "name" => n} when is_binary(n) and n != "" -> [n]
          _ -> []
        end)

      _ ->
        []
    end)
    |> Enum.reject(&(&1 == module_path || &1 == ""))
  end

  # --- Import extraction ---

  @doc false
  def extract_imports(ast) do
    ast
    |> find_nodes(["import_statement", "import_from_statement"])
    |> Enum.map(&extract_import_source/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp extract_import_source(%{"kind" => "import_statement", "children" => children}) do
    # import X / import X.Y
    children
    |> Enum.find(&(&1["kind"] in ["dotted_name", "identifier"]))
    |> case do
      %{"text" => text} when is_binary(text) and text != "" ->
        text

      %{"name" => name} when is_binary(name) and name != "" ->
        name

      %{"children" => parts} ->
        parts
        |> Enum.filter(&(&1["kind"] == "identifier"))
        |> Enum.map(&(&1["text"] || &1["name"] || ""))
        |> Enum.reject(&(&1 == ""))
        |> Enum.join(".")

      _ ->
        nil
    end
  end

  defp extract_import_source(%{"kind" => "import_from_statement", "children" => children}) do
    # from X import Y
    children
    |> Enum.find(&(&1["kind"] in ["dotted_name", "relative_import", "identifier"]))
    |> case do
      %{"text" => text} when is_binary(text) and text != "" ->
        text

      %{"name" => name} when is_binary(name) and name != "" ->
        name

      %{"children" => parts} ->
        parts
        |> Enum.filter(&(&1["kind"] == "identifier"))
        |> Enum.map(&(&1["text"] || &1["name"] || ""))
        |> Enum.reject(&(&1 == ""))
        |> Enum.join(".")

      _ ->
        nil
    end
  end

  defp extract_import_source(_), do: nil

  # --- AST helpers ---

  defp find_nodes(%{"kind" => kind, "children" => children} = node, target_kinds) do
    current = if kind in target_kinds, do: [node], else: []
    current ++ Enum.flat_map(children, &find_nodes(&1, target_kinds))
  end

  defp find_nodes(%{"kind" => kind} = node, target_kinds) do
    if kind in target_kinds, do: [node], else: []
  end

  defp find_nodes(_, _), do: []
end
