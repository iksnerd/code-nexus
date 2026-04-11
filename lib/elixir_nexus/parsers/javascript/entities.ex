defmodule ElixirNexus.Parsers.JavaScript.Entities do
  @moduledoc "Entity extraction from JavaScript/TypeScript tree-sitter ASTs."

  alias ElixirNexus.CodeSchema
  alias ElixirNexus.Parsers.JavaScript.Calls

  @doc "Walk a tree-sitter AST and collect declaration nodes."
  def walk_ast(%{"kind" => kind, "children" => children} = node, acc) do
    acc =
      case kind do
        "function_declaration" ->
          [node | acc]

        "method_definition" ->
          [node | acc]

        "class_declaration" ->
          [node | acc]

        "export_statement" ->
          # Collect inner declarations; skip recursing into this node's children
          # to avoid duplicates (the inner declaration would be found again)
          collect_export_declaration(node, acc)

        "arrow_function" ->
          if has_name_context?(node), do: [node | acc], else: acc

        "lexical_declaration" ->
          [node | acc]

        "variable_declaration" ->
          [node | acc]

        "interface_declaration" ->
          [node | acc]

        "type_alias_declaration" ->
          [node | acc]

        _ ->
          acc
      end

    # Don't recurse into export_statement children (already handled above)
    if kind == "export_statement" do
      acc
    else
      Enum.reduce(children, acc, &walk_ast/2)
    end
  end

  def walk_ast(%{"kind" => kind} = node, acc) do
    case kind do
      "function_declaration" -> [node | acc]
      "method_definition" -> [node | acc]
      "class_declaration" -> [node | acc]
      "interface_declaration" -> [node | acc]
      _ -> acc
    end
  end

  def walk_ast(_, acc), do: acc

  @doc "Convert a declaration AST node to a CodeSchema struct."
  def to_code_schema(file_path, node, source) do
    kind = node["kind"]
    name = node["name"] || extract_name_from_fields(node) || extract_name_from_declarator(node)
    start_line = (node["start_row"] || 0) + 1
    end_line = (node["end_row"] || 0) + 1

    {entity_type, visibility} =
      case kind do
        "function_declaration" -> {:function, :public}
        "method_definition" -> {:method, :public}
        "class_declaration" -> {:class, :public}
        "arrow_function" -> {:function, :private}
        "interface_declaration" -> {:interface, :public}
        "type_alias_declaration" -> {:struct, :public}
        "lexical_declaration" -> classify_variable_declaration(node)
        "variable_declaration" -> classify_variable_declaration(node)
        _ -> {:function, nil}
      end

    if name do
      %CodeSchema{
        file_path: file_path,
        entity_type: entity_type,
        name: name,
        content: extract_content(source, start_line, end_line),
        start_line: start_line,
        end_line: end_line,
        parameters: extract_params(node),
        visibility: visibility,
        calls: Calls.extract_calls(node),
        is_a: extract_extends(node),
        contains: extract_contains(node),
        language: :javascript
      }
    end
  end

  @doc "Extract name from fields map (e.g. tree-sitter 'name' field)."
  def extract_name_from_fields(%{"fields" => %{"name" => name}}), do: name
  def extract_name_from_fields(_), do: nil

  @doc "Extract name from `const Foo = ...` style declarations."
  def extract_name_from_declarator(%{"children" => children}) do
    children
    |> Enum.find(fn child ->
      child["kind"] in ["variable_declarator", "lexical_binding"]
    end)
    |> case do
      %{"name" => name} when is_binary(name) ->
        name

      %{"children" => inner} ->
        inner
        |> Enum.find(&(&1["kind"] == "identifier"))
        |> case do
          %{"text" => text} -> text
          %{"name" => name} -> name
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def extract_name_from_declarator(_), do: nil

  # Extract the inner declaration from an export statement
  defp collect_export_declaration(%{"children" => children}, acc) do
    children
    |> Enum.filter(fn child ->
      child["kind"] in [
        "function_declaration",
        "class_declaration",
        "lexical_declaration",
        "variable_declaration",
        "interface_declaration",
        "type_alias_declaration"
      ]
    end)
    |> Enum.reduce(acc, fn child, inner_acc -> [child | inner_acc] end)
  end

  defp collect_export_declaration(_, acc), do: acc

  # Arrow functions don't have a "name" field in tree-sitter; they get their name
  # from the parent variable_declarator when captured as lexical/variable_declaration.
  defp has_name_context?(%{"name" => name}) when is_binary(name) and name != "", do: true
  defp has_name_context?(%{"kind" => "arrow_function"}), do: false
  defp has_name_context?(_), do: false

  # Classify variable declarations by inspecting the value being assigned.
  # `const f = () => {}` → function, `const Config = {...}` → variable
  defp classify_variable_declaration(%{"children" => children}) do
    declarator = Enum.find(children, &(&1["kind"] in ["variable_declarator", "lexical_binding"]))
    value_kind = get_declarator_value_kind(declarator)

    case value_kind do
      k when k in ["arrow_function", "function_expression", "function"] ->
        {:function, :private}

      k when k in ["class_expression", "class"] ->
        {:class, :private}

      _ ->
        {:variable, :public}
    end
  end

  defp classify_variable_declaration(_), do: {:variable, :public}

  defp get_declarator_value_kind(%{"children" => children}) do
    # The value is the last child (after the name identifier and "=" token)
    children
    |> List.last()
    |> case do
      %{"kind" => kind} -> kind
      _ -> nil
    end
  end

  defp get_declarator_value_kind(_), do: nil

  defp extract_content(source, start_line, end_line) when start_line > 0 and end_line > 0 do
    source
    |> String.split("\n")
    |> Enum.slice((start_line - 1)..(end_line - 1))
    |> Enum.join("\n")
  end

  defp extract_content(_, _, _), do: ""

  defp extract_params(%{"children" => children}) do
    children
    |> Enum.filter(&(&1["kind"] in ["formal_parameters", "parameter_list"]))
    |> Enum.flat_map(fn params ->
      (params["children"] || [])
      |> Enum.filter(&(&1["kind"] in ["identifier", "required_parameter", "optional_parameter"]))
      |> Enum.map(&(&1["name"] || &1["text"] || ""))
    end)
  end

  defp extract_params(_), do: []

  defp extract_extends(%{"children" => children}) do
    children
    |> Enum.filter(&(&1["kind"] in ["extends_clause", "implements_clause"]))
    |> Enum.flat_map(fn clause ->
      (clause["children"] || [])
      |> Enum.filter(&(&1["kind"] == "identifier"))
      |> Enum.map(&(&1["text"] || ""))
    end)
  end

  defp extract_extends(_), do: []

  defp extract_contains(%{"kind" => "class_declaration", "children" => children}) do
    children
    |> Enum.filter(&(&1["kind"] == "method_definition"))
    |> Enum.map(&(&1["name"] || ""))
    |> Enum.reject(&(&1 == ""))
  end

  defp extract_contains(_), do: []
end
