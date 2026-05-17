defmodule ElixirNexus.Parsers.RustExtractor do
  @moduledoc """
  Entity extractor for Rust ASTs from tree-sitter.
  Extracts functions, methods, structs/enums/traits, `use` imports, and call edges.
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

    declarations =
      Enum.map(declarations, fn entity ->
        %{entity | is_a: Enum.uniq(entity.is_a ++ imports)}
      end)

    file_entity =
      if imports != [] or declarations != [] do
        [
          %CodeSchema{
            file_path: file_path,
            entity_type: :module,
            name: Path.basename(file_path, ".rs"),
            content: "",
            start_line: 1,
            end_line: 1,
            parameters: [],
            visibility: :public,
            calls: short_names_of(imports),
            is_a: imports,
            contains: declarations |> Enum.map(& &1.name) |> Enum.reject(&is_nil/1),
            language: :rust
          }
        ]
      else
        []
      end

    file_entity ++ declarations
  end

  defp walk_ast(%{"kind" => kind, "children" => children} = node, parent, acc) do
    acc =
      case kind do
        "function_item" -> [{node, parent} | acc]
        "struct_item" -> [{node, nil} | acc]
        "enum_item" -> [{node, nil} | acc]
        "trait_item" -> [{node, nil} | acc]
        "mod_item" -> [{node, nil} | acc]
        _ -> acc
      end

    new_parent =
      case kind do
        "impl_item" -> extract_impl_type(node)
        "trait_item" -> node["name"] || parent
        _ -> parent
      end

    Enum.reduce(children, acc, &walk_ast(&1, new_parent, &2))
  end

  defp walk_ast(%{"kind" => kind} = node, parent, acc) do
    case kind do
      "function_item" -> [{node, parent} | acc]
      "struct_item" -> [{node, nil} | acc]
      "enum_item" -> [{node, nil} | acc]
      "trait_item" -> [{node, nil} | acc]
      "mod_item" -> [{node, nil} | acc]
      _ -> acc
    end
  end

  defp walk_ast(_, _, acc), do: acc

  defp to_code_schema(file_path, {node, parent}, source) do
    kind = node["kind"]
    name = node["name"]
    start_line = (node["start_row"] || 0) + 1
    end_line = (node["end_row"] || 0) + 1
    visibility = rust_visibility(node)

    {entity_type, full_name} =
      case kind do
        "function_item" ->
          type = if parent, do: :method, else: :function
          full = if parent && type == :method, do: "#{parent}.#{name}", else: name
          {type, full}

        "struct_item" ->
          {:struct, name}

        "enum_item" ->
          {:enum, name}

        "trait_item" ->
          {:interface, name}

        "mod_item" ->
          {:module, name}

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
        module_path: parent,
        parameters: extract_params(node),
        visibility: visibility,
        calls: extract_calls(node),
        is_a: [],
        contains: extract_contains(node),
        language: :rust
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

  defp rust_visibility(%{"children" => children}) do
    # In Rust tree-sitter, the presence of a `visibility_modifier` child means the
    # item is exported (`pub`, `pub(crate)`, etc.). Absent means module-private.
    has_pub = Enum.any?(children, &(&1["kind"] == "visibility_modifier"))
    if has_pub, do: :public, else: :private
  end

  defp rust_visibility(_), do: :private

  defp extract_impl_type(%{"children" => children}) do
    children
    |> Enum.find(&(&1["kind"] in ["type_identifier", "scoped_type_identifier", "generic_type"]))
    |> case do
      %{"text" => t} when is_binary(t) and t != "" ->
        t

      %{"name" => n} when is_binary(n) and n != "" ->
        n

      %{"children" => grand} ->
        Enum.find_value(grand, fn c ->
          if c["kind"] == "type_identifier", do: c["text"] || c["name"]
        end)

      _ ->
        nil
    end
  end

  defp extract_impl_type(_), do: nil

  defp extract_params(%{"children" => children}) do
    children
    |> Enum.filter(&(&1["kind"] == "parameters"))
    |> Enum.flat_map(fn params ->
      (params["children"] || [])
      |> Enum.filter(&(&1["kind"] in ["parameter", "self_parameter"]))
      |> Enum.flat_map(fn
        %{"kind" => "self_parameter"} ->
          ["self"]

        p ->
          (p["children"] || [])
          |> Enum.filter(&(&1["kind"] == "identifier"))
          |> Enum.map(&(&1["text"] || &1["name"] || ""))
          |> Enum.reject(&(&1 == ""))
      end)
    end)
  end

  defp extract_params(_), do: []

  defp extract_calls(%{"children" => children}) do
    children
    |> Enum.flat_map(&find_calls/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp extract_calls(_), do: []

  defp find_calls(%{"kind" => "call_expression", "children" => children}) do
    callee =
      children
      |> Enum.find(&(&1["kind"] in ["identifier", "scoped_identifier", "field_expression"]))
      |> callee_name()

    rest = Enum.flat_map(children, &find_calls/1)
    if callee, do: [callee | rest], else: rest
  end

  defp find_calls(%{"kind" => "macro_invocation", "children" => children}) do
    macro =
      children
      |> Enum.find(&(&1["kind"] in ["identifier", "scoped_identifier"]))
      |> callee_name()

    rest = Enum.flat_map(children, &find_calls/1)
    if macro, do: ["#{macro}!" | rest], else: rest
  end

  defp find_calls(%{"children" => children}), do: Enum.flat_map(children, &find_calls/1)
  defp find_calls(_), do: []

  defp callee_name(nil), do: nil
  defp callee_name(%{"text" => t}) when is_binary(t) and t != "", do: t
  defp callee_name(%{"name" => n}) when is_binary(n) and n != "", do: n

  defp callee_name(%{"kind" => "scoped_identifier", "children" => children}) do
    children
    |> Enum.filter(&(&1["kind"] in ["identifier", "scoped_identifier"]))
    |> Enum.map(&(&1["text"] || &1["name"] || ""))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("::")
    |> case do
      "" -> nil
      s -> s
    end
  end

  defp callee_name(%{"kind" => "field_expression", "children" => children}) do
    children
    |> Enum.find(&(&1["kind"] == "field_identifier"))
    |> case do
      %{"text" => t} when is_binary(t) -> t
      %{"name" => n} when is_binary(n) -> n
      _ -> nil
    end
  end

  defp callee_name(_), do: nil

  defp extract_contains(%{"kind" => "impl_item", "children" => children}) do
    children
    |> Enum.flat_map(fn
      %{"kind" => "declaration_list", "children" => grand} ->
        grand |> Enum.filter(&(&1["kind"] == "function_item")) |> Enum.map(& &1["name"])

      %{"kind" => "function_item"} = node ->
        [node["name"]]

      _ ->
        []
    end)
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp extract_contains(_), do: []

  @doc false
  def extract_imports(ast) do
    ast
    |> find_nodes("use_declaration")
    |> Enum.flat_map(&extract_use_paths/1)
    |> Enum.uniq()
  end

  defp extract_use_paths(%{"children" => children}) do
    children
    |> Enum.flat_map(fn child ->
      case child["kind"] do
        "scoped_identifier" -> [scoped_to_path(child)]
        "use_as_clause" -> use_as_clause_path(child)
        "use_list" -> []
        "identifier" -> [child["text"] || child["name"]]
        _ -> []
      end
    end)
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp extract_use_paths(_), do: []

  defp use_as_clause_path(%{"children" => children}) do
    children
    |> Enum.filter(&(&1["kind"] in ["scoped_identifier", "identifier"]))
    |> Enum.take(1)
    |> Enum.map(&scoped_to_path/1)
  end

  defp use_as_clause_path(_), do: []

  defp scoped_to_path(%{"kind" => "identifier"} = node), do: node["text"] || node["name"]
  defp scoped_to_path(%{"text" => t}) when is_binary(t) and t != "", do: t

  defp scoped_to_path(%{"children" => children}) do
    children
    |> Enum.filter(&(&1["kind"] in ["identifier", "scoped_identifier"]))
    |> Enum.map(&scoped_to_path/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("::")
  end

  defp scoped_to_path(_), do: nil

  defp short_names_of(imports) do
    imports
    |> Enum.map(fn path -> path |> String.split("::") |> List.last() end)
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
