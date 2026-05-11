defmodule ElixirNexus.Parsers.JavaExtractor do
  @moduledoc """
  Entity extractor for Java ASTs from tree-sitter.
  Extracts classes/interfaces/enums/records, methods, imports, and method calls.
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
    package_name = extract_package_name(ast)

    declarations =
      Enum.map(declarations, fn entity ->
        %{entity | is_a: Enum.uniq(entity.is_a ++ imports)}
      end)

    file_entity =
      if imports != [] or declarations != [] do
        module_name = package_name || Path.basename(file_path, ".java")

        [
          %CodeSchema{
            file_path: file_path,
            entity_type: :module,
            name: module_name,
            content: "",
            start_line: 1,
            end_line: 1,
            parameters: [],
            visibility: :public,
            calls: short_names_of(imports),
            is_a: imports,
            contains: declarations |> Enum.map(& &1.name) |> Enum.reject(&is_nil/1),
            language: :java
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
        k when k in ["class_declaration", "interface_declaration", "enum_declaration", "record_declaration"] ->
          [{node, nil} | acc]

        "method_declaration" ->
          [{node, parent_class} | acc]

        "constructor_declaration" ->
          [{node, parent_class} | acc]

        _ ->
          acc
      end

    new_parent =
      case kind do
        k when k in ["class_declaration", "interface_declaration", "enum_declaration", "record_declaration"] ->
          node["name"]

        _ ->
          parent_class
      end

    Enum.reduce(children, acc, &walk_ast(&1, new_parent, &2))
  end

  defp walk_ast(%{"kind" => kind} = node, parent_class, acc) do
    case kind do
      k when k in ["class_declaration", "interface_declaration", "enum_declaration", "record_declaration"] ->
        [{node, nil} | acc]

      "method_declaration" ->
        [{node, parent_class} | acc]

      "constructor_declaration" ->
        [{node, parent_class} | acc]

      _ ->
        acc
    end
  end

  defp walk_ast(_, _, acc), do: acc

  defp to_code_schema(file_path, {node, parent_class}, source) do
    kind = node["kind"]
    name = node["name"]
    start_line = (node["start_row"] || 0) + 1
    end_line = (node["end_row"] || 0) + 1
    visibility = java_visibility(node)

    {entity_type, full_name} =
      case kind do
        "class_declaration" ->
          {:class, name}

        "interface_declaration" ->
          {:interface, name}

        "enum_declaration" ->
          {:enum, name}

        "record_declaration" ->
          {:class, name}

        "method_declaration" ->
          full = if parent_class, do: "#{parent_class}.#{name}", else: name
          {:method, full}

        "constructor_declaration" ->
          full = if parent_class, do: "#{parent_class}.#{name}", else: name
          {:method, full}

        _ ->
          {:function, name}
      end

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
        is_a: extract_supertypes(node),
        contains: extract_contains(node),
        language: :java
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

  defp java_visibility(%{"children" => children}) do
    modifiers =
      children
      |> Enum.find(&(&1["kind"] == "modifiers"))

    cond do
      modifiers == nil -> :public
      modifiers_contains?(modifiers, "private") -> :private
      modifiers_contains?(modifiers, "protected") -> :private
      modifiers_contains?(modifiers, "public") -> :public
      true -> :public
    end
  end

  defp java_visibility(_), do: :public

  defp modifiers_contains?(%{"children" => children}, keyword) do
    Enum.any?(children, fn c ->
      c["kind"] == keyword or
        (c["text"] || c["name"] || "") == keyword
    end)
  end

  defp modifiers_contains?(_, _), do: false

  defp extract_params(%{"children" => children}) do
    children
    |> Enum.filter(&(&1["kind"] == "formal_parameters"))
    |> Enum.flat_map(fn params ->
      (params["children"] || [])
      |> Enum.filter(&(&1["kind"] in ["formal_parameter", "spread_parameter"]))
      |> Enum.map(fn p ->
        (p["children"] || [])
        |> Enum.find(&(&1["kind"] == "identifier"))
        |> case do
          %{"text" => t} when is_binary(t) -> t
          %{"name" => n} when is_binary(n) -> n
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
    end)
  end

  defp extract_params(_), do: []

  defp extract_supertypes(%{"children" => children}) do
    children
    |> Enum.flat_map(fn child ->
      case child["kind"] do
        "superclass" -> type_names_from(child)
        "super_interfaces" -> type_names_from(child)
        "extends_interfaces" -> type_names_from(child)
        _ -> []
      end
    end)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp extract_supertypes(_), do: []

  defp type_names_from(%{"children" => children}) do
    children
    |> Enum.flat_map(fn child ->
      case child["kind"] do
        "type_identifier" -> [child["text"] || child["name"]]
        "type_list" -> type_names_from(child)
        "interface_type_list" -> type_names_from(child)
        "generic_type" -> [child["text"] || child["name"]]
        _ -> []
      end
    end)
  end

  defp type_names_from(_), do: []

  defp extract_calls(%{"children" => children}) do
    children
    |> Enum.flat_map(&find_calls/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp extract_calls(_), do: []

  defp find_calls(%{"kind" => "method_invocation"} = node) do
    name =
      case node do
        %{"name" => n} when is_binary(n) and n != "" -> n
        _ -> extract_invocation_name(node)
      end

    rest = Enum.flat_map(node["children"] || [], &find_calls/1)
    if name, do: [name | rest], else: rest
  end

  defp find_calls(%{"kind" => "object_creation_expression", "children" => children}) do
    name =
      children
      |> Enum.find(&(&1["kind"] in ["type_identifier", "scoped_type_identifier", "generic_type"]))
      |> case do
        %{"text" => t} when is_binary(t) and t != "" -> "new " <> t
        %{"name" => n} when is_binary(n) and n != "" -> "new " <> n
        _ -> nil
      end

    rest = Enum.flat_map(children, &find_calls/1)
    if name, do: [name | rest], else: rest
  end

  defp find_calls(%{"children" => children}), do: Enum.flat_map(children, &find_calls/1)
  defp find_calls(_), do: []

  defp extract_invocation_name(%{"children" => children}) do
    children
    |> Enum.filter(&(&1["kind"] in ["identifier", "field_access"]))
    |> Enum.map(&(&1["text"] || &1["name"]))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> List.last()
  end

  defp extract_invocation_name(_), do: nil

  defp extract_contains(%{"children" => children}) do
    children
    |> Enum.flat_map(fn
      %{"kind" => "class_body", "children" => grand} ->
        grand
        |> Enum.filter(&(&1["kind"] in ["method_declaration", "constructor_declaration"]))
        |> Enum.map(& &1["name"])

      %{"kind" => "interface_body", "children" => grand} ->
        grand
        |> Enum.filter(&(&1["kind"] == "method_declaration"))
        |> Enum.map(& &1["name"])

      _ ->
        []
    end)
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  @doc false
  def extract_imports(ast) do
    ast
    |> find_nodes("import_declaration")
    |> Enum.map(&extract_import_path/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp extract_import_path(%{"children" => children}) do
    children
    |> Enum.find(&(&1["kind"] in ["scoped_identifier", "identifier", "asterisk"]))
    |> case do
      %{"text" => t} when is_binary(t) and t != "" -> t
      %{"name" => n} when is_binary(n) and n != "" -> n
      %{"kind" => "scoped_identifier"} = node -> scoped_to_dotted(node)
      _ -> nil
    end
  end

  defp extract_import_path(_), do: nil

  defp scoped_to_dotted(%{"children" => children}) do
    children
    |> Enum.filter(&(&1["kind"] in ["identifier", "scoped_identifier"]))
    |> Enum.map(fn
      %{"kind" => "identifier"} = node -> node["text"] || node["name"]
      %{"kind" => "scoped_identifier"} = node -> scoped_to_dotted(node)
    end)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(".")
  end

  defp scoped_to_dotted(_), do: nil

  defp extract_package_name(ast) do
    ast
    |> find_nodes("package_declaration")
    |> Enum.flat_map(fn node ->
      (node["children"] || [])
      |> Enum.filter(&(&1["kind"] in ["scoped_identifier", "identifier"]))
      |> Enum.map(fn
        %{"kind" => "identifier"} = c -> c["text"] || c["name"]
        %{"kind" => "scoped_identifier"} = c -> scoped_to_dotted(c)
      end)
    end)
    |> Enum.reject(&is_nil/1)
    |> List.first()
  end

  defp short_names_of(imports) do
    imports
    |> Enum.map(fn path -> path |> String.split(".") |> List.last() end)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp find_nodes(%{"kind" => kind, "children" => children} = node, target_kind) do
    current = if kind == target_kind, do: [node], else: []
    current ++ Enum.flat_map(children, &find_nodes(&1, target_kind))
  end

  defp find_nodes(%{"kind" => kind} = node, target_kind) do
    if kind == target_kind, do: [node], else: []
  end

  defp find_nodes(_, _), do: []
end
