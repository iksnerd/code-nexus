defmodule ElixirNexus.Parsers.PythonExtractor do
  @moduledoc """
  Entity extractor for Python ASTs from tree-sitter.
  Extracts functions, classes, methods, decorators, and imports.
  """

  alias ElixirNexus.CodeSchema

  @doc "Extract code entities from a tree-sitter AST."
  def extract_entities(file_path, ast, source) do
    declarations =
      ast
      |> walk_ast(nil, [])
      |> Enum.map(&to_code_schema(file_path, &1, source))
      |> Enum.reject(&is_nil/1)

    imports = extract_imports(ast)

    # Enrich declarations with import info
    declarations =
      Enum.map(declarations, fn entity ->
        %{entity | is_a: Enum.uniq(entity.is_a ++ imports)}
      end)

    # Create a file-level module entity if there are imports
    file_entity =
      if imports != [] do
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
            calls: extract_imported_names(ast),
            is_a: imports,
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

  defp to_code_schema(file_path, {node, parent_class}, source) do
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
        calls: extract_calls(node),
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

  defp extract_calls(%{"children" => children}) do
    children
    |> Enum.flat_map(&find_calls/1)
    |> Enum.uniq()
  end

  defp extract_calls(_), do: []

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

  # Extract imported names for the file-level module's calls list
  defp extract_imported_names(ast) do
    ast
    |> find_nodes(["import_statement", "import_from_statement"])
    |> Enum.flat_map(&extract_import_identifiers/1)
    |> Enum.uniq()
  end

  defp extract_import_identifiers(%{"kind" => "import_from_statement", "children" => children}) do
    # from X import a, b, c — extract a, b, c
    children
    |> Enum.filter(&(&1["kind"] in ["identifier", "import_list", "aliased_import"]))
    |> Enum.flat_map(fn
      %{"kind" => "identifier", "text" => text} when is_binary(text) ->
        [text]

      %{"kind" => "identifier", "name" => name} when is_binary(name) ->
        [name]

      %{"kind" => "import_list", "children" => list_children} ->
        list_children
        |> Enum.filter(&(&1["kind"] in ["identifier", "aliased_import"]))
        |> Enum.map(fn
          %{"kind" => "identifier", "text" => text} -> text
          %{"kind" => "identifier", "name" => name} -> name
          %{"kind" => "aliased_import", "name" => name} -> name
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end)
    # Filter out the module name itself (first identifier is usually the source module)
    |> Enum.reject(fn name ->
      Enum.any?(children, fn child ->
        child["kind"] in ["dotted_name", "relative_import"] and
          (child["text"] == name or child["name"] == name)
      end)
    end)
  end

  defp extract_import_identifiers(%{"kind" => "import_statement", "children" => children}) do
    # import X — the module itself is what's imported
    children
    |> Enum.filter(&(&1["kind"] in ["dotted_name", "identifier"]))
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      %{"name" => name} when is_binary(name) -> name
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_import_identifiers(_), do: []

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
