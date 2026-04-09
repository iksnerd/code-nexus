defmodule ElixirNexus.Parsers.GoExtractor do
  @moduledoc """
  Entity extractor for Go ASTs from tree-sitter.
  Extracts functions, methods, type declarations (structs/interfaces),
  call expressions, and import declarations.
  """

  alias ElixirNexus.CodeSchema

  @doc "Extract code entities from a tree-sitter AST."
  def extract_entities(file_path, ast, source) do
    declarations =
      ast
      |> walk_ast([])
      |> Enum.map(&to_code_schema(file_path, &1, source))
      |> Enum.reject(&is_nil/1)

    imports = extract_imports(ast)
    package_name = extract_package_name(ast)

    # Enrich declarations with import info
    declarations =
      Enum.map(declarations, fn entity ->
        %{entity | is_a: Enum.uniq(entity.is_a ++ imports)}
      end)

    # Create a file-level module entity
    exported_names =
      declarations
      |> Enum.map(& &1.name)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&exported?/1)

    file_entity =
      if package_name || imports != [] do
        module_name = package_name || Path.basename(file_path, ".go")

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
            calls: extract_imported_package_names(ast),
            is_a: imports,
            contains: exported_names,
            language: :go
          }
        ]
      else
        []
      end

    file_entity ++ declarations
  end

  # --- AST walking ---

  defp walk_ast(%{"kind" => kind, "children" => children} = node, acc) do
    acc =
      case kind do
        "function_declaration" -> [node | acc]
        "method_declaration" -> [node | acc]
        "type_declaration" -> collect_type_specs(node, acc)
        _ -> acc
      end

    # Don't recurse into type_declaration children (already handled)
    if kind == "type_declaration" do
      acc
    else
      Enum.reduce(children, acc, &walk_ast/2)
    end
  end

  defp walk_ast(%{"kind" => kind} = node, acc) do
    case kind do
      "function_declaration" -> [node | acc]
      "method_declaration" -> [node | acc]
      _ -> acc
    end
  end

  defp walk_ast(_, acc), do: acc

  # type_declaration contains one or more type_spec children
  defp collect_type_specs(%{"children" => children}, acc) do
    children
    |> Enum.filter(&(&1["kind"] == "type_spec"))
    |> Enum.reduce(acc, fn spec, inner_acc -> [spec | inner_acc] end)
  end

  defp collect_type_specs(_, acc), do: acc

  # --- Schema conversion ---

  defp to_code_schema(file_path, node, source) do
    kind = node["kind"]
    start_line = (node["start_row"] || 0) + 1
    end_line = (node["end_row"] || 0) + 1

    case kind do
      "function_declaration" ->
        name = extract_function_name(node)
        build_entity(file_path, :function, name, node, source, start_line, end_line)

      "method_declaration" ->
        {receiver_type, method_name} = extract_method_info(node)
        full_name = if receiver_type, do: "#{receiver_type}.#{method_name}", else: method_name
        build_entity(file_path, :method, full_name, node, source, start_line, end_line)

      "type_spec" ->
        {entity_type, contains} = classify_type_spec(node)
        name = extract_type_spec_name(node)

        if name do
          %CodeSchema{
            file_path: file_path,
            entity_type: entity_type,
            name: name,
            content: extract_content(source, start_line, end_line),
            start_line: start_line,
            end_line: end_line,
            parameters: [],
            visibility: go_visibility(name),
            calls: [],
            is_a: [],
            contains: contains,
            language: :go
          }
        end

      _ ->
        nil
    end
  end

  defp build_entity(file_path, entity_type, name, node, source, start_line, end_line) do
    if name do
      # For methods, visibility is based on the method name (after the dot)
      vis_name =
        case entity_type do
          :method -> name |> String.split(".") |> List.last()
          _ -> name
        end

      %CodeSchema{
        file_path: file_path,
        entity_type: entity_type,
        name: name,
        content: extract_content(source, start_line, end_line),
        start_line: start_line,
        end_line: end_line,
        parameters: extract_params(node),
        visibility: go_visibility(vis_name),
        calls: extract_calls(node),
        is_a: [],
        contains: [],
        language: :go
      }
    end
  end

  # --- Name extraction ---

  # Extract function name from function_declaration node.
  # Try top-level "name" field first, then look for identifier child.
  defp extract_function_name(%{"name" => name}) when is_binary(name) and name != "", do: name

  defp extract_function_name(%{"children" => children}) do
    children
    |> Enum.find(&(&1["kind"] == "identifier"))
    |> case do
      %{"text" => text} when is_binary(text) -> text
      %{"name" => name} when is_binary(name) -> name
      _ -> nil
    end
  end

  defp extract_function_name(_), do: nil

  # Extract receiver type and method name from method_declaration.
  # method_declaration children: parameter_list (receiver), field_identifier (name),
  #   parameter_list (params), block
  defp extract_method_info(%{"children" => children}) do
    receiver_type = extract_receiver_type(children)
    method_name = extract_method_name(children)
    {receiver_type, method_name}
  end

  defp extract_method_info(_), do: {nil, nil}

  defp extract_receiver_type(children) do
    # The first parameter_list is the receiver
    children
    |> Enum.find(&(&1["kind"] == "parameter_list"))
    |> case do
      %{"children" => receiver_children} ->
        find_receiver_type_name(receiver_children)

      _ ->
        nil
    end
  end

  # Look for type_identifier inside the receiver parameter_list.
  # Handles both value receivers (t MyType) and pointer receivers (t *MyType).
  defp find_receiver_type_name(children) do
    children
    |> Enum.flat_map(fn child ->
      case child["kind"] do
        "type_identifier" ->
          [child["text"] || child["name"]]

        "pointer_type" ->
          find_type_identifier_in(child)

        "parameter_declaration" ->
          find_type_identifier_in(child)

        _ ->
          []
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> List.first()
  end

  defp find_type_identifier_in(%{"children" => children}) do
    Enum.flat_map(children, fn child ->
      case child["kind"] do
        "type_identifier" -> [child["text"] || child["name"]]
        "pointer_type" -> find_type_identifier_in(child)
        _ -> []
      end
    end)
  end

  defp find_type_identifier_in(_), do: []

  defp extract_method_name(children) do
    children
    |> Enum.find(&(&1["kind"] == "field_identifier"))
    |> case do
      %{"text" => text} when is_binary(text) -> text
      %{"name" => name} when is_binary(name) -> name
      _ -> nil
    end
  end

  # Extract name from type_spec node
  defp extract_type_spec_name(%{"name" => name}) when is_binary(name) and name != "", do: name

  defp extract_type_spec_name(%{"children" => children}) do
    children
    |> Enum.find(&(&1["kind"] == "type_identifier"))
    |> case do
      %{"text" => text} when is_binary(text) -> text
      %{"name" => name} when is_binary(name) -> name
      _ -> nil
    end
  end

  defp extract_type_spec_name(_), do: nil

  # Classify type_spec as struct, interface, or generic type
  defp classify_type_spec(%{"children" => children}) do
    type_node = Enum.find(children, &(&1["kind"] in ["struct_type", "interface_type"]))

    case type_node do
      %{"kind" => "struct_type"} ->
        {:struct, extract_struct_fields(type_node)}

      %{"kind" => "interface_type"} ->
        {:interface, extract_interface_methods(type_node)}

      _ ->
        {:struct, []}
    end
  end

  defp classify_type_spec(_), do: {:struct, []}

  defp extract_struct_fields(%{"children" => children}) do
    children
    |> Enum.filter(&(&1["kind"] == "field_declaration"))
    |> Enum.flat_map(fn field ->
      (field["children"] || [])
      |> Enum.filter(&(&1["kind"] == "field_identifier"))
      |> Enum.map(&(&1["text"] || &1["name"] || ""))
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp extract_struct_fields(_), do: []

  defp extract_interface_methods(%{"children" => children}) do
    children
    |> Enum.filter(&(&1["kind"] in ["method_spec", "method_elem"]))
    |> Enum.flat_map(fn method ->
      case method do
        %{"name" => name} when is_binary(name) ->
          [name]

        %{"children" => method_children} ->
          method_children
          |> Enum.filter(&(&1["kind"] == "field_identifier"))
          |> Enum.map(&(&1["text"] || &1["name"] || ""))

        _ ->
          []
      end
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp extract_interface_methods(_), do: []

  # --- Parameter extraction ---

  defp extract_params(%{"kind" => "method_declaration", "children" => children}) do
    # For methods, skip the first parameter_list (receiver) and use the second
    children
    |> Enum.filter(&(&1["kind"] == "parameter_list"))
    |> Enum.drop(1)
    |> Enum.take(1)
    |> Enum.flat_map(&extract_param_identifiers/1)
  end

  defp extract_params(%{"children" => children}) do
    children
    |> Enum.filter(&(&1["kind"] == "parameter_list"))
    |> Enum.take(1)
    |> Enum.flat_map(&extract_param_identifiers/1)
  end

  defp extract_params(_), do: []

  defp extract_param_identifiers(%{"children" => children}) do
    children
    |> Enum.filter(&(&1["kind"] == "parameter_declaration"))
    |> Enum.flat_map(fn param ->
      (param["children"] || [])
      |> Enum.filter(&(&1["kind"] == "identifier"))
      |> Enum.map(&(&1["text"] || &1["name"] || ""))
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp extract_param_identifiers(_), do: []

  # --- Call extraction ---

  defp extract_calls(%{"children" => children}) do
    children
    |> Enum.flat_map(&find_calls/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp extract_calls(_), do: []

  # call_expression with a top-level name (unlikely in Go tree-sitter, but handle it)
  defp find_calls(%{"kind" => "call_expression", "name" => name}) when is_binary(name) and name != "" do
    [name]
  end

  # call_expression — extract callee from children
  defp find_calls(%{"kind" => "call_expression", "children" => children}) do
    callee_node =
      Enum.find(children, fn child ->
        child["kind"] in ["identifier", "selector_expression", "call_expression"]
      end)

    callee_name = extract_callee_name(callee_node)

    # Recurse into argument_list for nested calls
    arg_calls =
      children
      |> Enum.filter(&(&1["kind"] == "argument_list"))
      |> Enum.flat_map(&find_calls/1)

    # Recurse into callee for chained calls
    callee_chain_calls = find_calls_in_callee(callee_node)

    all_calls = arg_calls ++ callee_chain_calls

    case callee_name do
      nil -> all_calls
      name -> [name | all_calls]
    end
  end

  defp find_calls(%{"kind" => "call_expression"}), do: []

  # Recurse into other nodes
  defp find_calls(%{"children" => children}), do: Enum.flat_map(children, &find_calls/1)
  defp find_calls(_), do: []

  # Extract callee name from the function child of a call_expression
  defp extract_callee_name(%{"kind" => "identifier", "text" => text}) when is_binary(text), do: text
  defp extract_callee_name(%{"kind" => "identifier", "name" => name}) when is_binary(name), do: name

  defp extract_callee_name(%{"kind" => "selector_expression", "children" => children}) do
    # selector_expression: operand (identifier) + field_identifier
    # e.g., fmt.Println -> ["fmt", "Println"] -> "fmt.Println"
    has_call_child = Enum.any?(children, &(&1["kind"] == "call_expression"))

    if has_call_child do
      # Chained: foo().Bar — extract just the field
      children
      |> Enum.find(&(&1["kind"] == "field_identifier"))
      |> case do
        %{"text" => t} when is_binary(t) -> t
        %{"name" => n} when is_binary(n) -> n
        _ -> nil
      end
    else
      # Simple: pkg.Function — join operand + field
      parts =
        children
        |> Enum.filter(&(&1["kind"] in ["identifier", "field_identifier"]))
        |> Enum.map(&(&1["text"] || &1["name"] || ""))
        |> Enum.reject(&(&1 == ""))

      case parts do
        [] -> nil
        _ -> Enum.join(parts, ".")
      end
    end
  end

  defp extract_callee_name(%{"kind" => "selector_expression", "text" => text}) when is_binary(text), do: text
  defp extract_callee_name(_), do: nil

  # Recurse into callee chain for chained calls
  defp find_calls_in_callee(%{"kind" => "selector_expression", "children" => children}) do
    children
    |> Enum.filter(&(&1["kind"] == "call_expression"))
    |> Enum.flat_map(&find_calls/1)
  end

  defp find_calls_in_callee(%{"kind" => "call_expression"} = node), do: find_calls(node)
  defp find_calls_in_callee(_), do: []

  # --- Import extraction ---

  @doc false
  def extract_imports(ast) do
    ast
    |> find_nodes("import_declaration")
    |> Enum.flat_map(&extract_import_paths/1)
    |> Enum.uniq()
  end

  defp extract_import_paths(%{"children" => children}) do
    children
    |> Enum.flat_map(fn child ->
      case child["kind"] do
        "import_spec_list" ->
          (child["children"] || [])
          |> Enum.filter(&(&1["kind"] == "import_spec"))
          |> Enum.flat_map(&extract_import_spec_path/1)

        "import_spec" ->
          extract_import_spec_path(child)

        "interpreted_string_literal" ->
          [clean_string(child["text"] || "")]

        _ ->
          []
      end
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp extract_import_paths(_), do: []

  defp extract_import_spec_path(%{"children" => children}) do
    children
    |> Enum.filter(&(&1["kind"] == "interpreted_string_literal"))
    |> Enum.map(fn node ->
      text = node["text"] || ""
      clean_string(text)
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp extract_import_spec_path(%{"text" => text}) when is_binary(text), do: [clean_string(text)]
  defp extract_import_spec_path(_), do: []

  # Extract short package names from imports for the module's calls list
  defp extract_imported_package_names(ast) do
    ast
    |> extract_imports()
    |> Enum.map(fn import_path ->
      # "fmt" -> "fmt", "net/http" -> "http", "github.com/foo/bar" -> "bar"
      import_path |> String.split("/") |> List.last() || import_path
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  # --- Package name extraction ---

  defp extract_package_name(ast) do
    ast
    |> find_nodes("package_clause")
    |> Enum.flat_map(fn node ->
      (node["children"] || [])
      |> Enum.filter(&(&1["kind"] == "package_identifier"))
      |> Enum.map(&(&1["text"] || &1["name"]))
    end)
    |> Enum.reject(&is_nil/1)
    |> List.first()
  end

  # --- Helpers ---

  defp extract_content(source, start_line, end_line) when start_line > 0 and end_line > 0 do
    source
    |> String.split("\n")
    |> Enum.slice((start_line - 1)..(end_line - 1))
    |> Enum.join("\n")
  end

  defp extract_content(_, _, _), do: ""

  defp clean_string(text), do: text |> String.trim("\"") |> String.trim("'")

  # In Go, exported identifiers start with an uppercase letter.
  # For dotted names like "Server.Handle", check the part after the dot.
  defp go_visibility(name) when is_binary(name) do
    check_name =
      case String.split(name, ".") do
        [_receiver, method] -> method
        _ -> name
      end

    case String.first(check_name) do
      nil ->
        :private

      first ->
        if first == String.upcase(first) and first != String.downcase(first),
          do: :public,
          else: :private
    end
  end

  defp go_visibility(_), do: :private

  defp exported?(name) when is_binary(name) do
    go_visibility(name) == :public
  end

  defp exported?(_), do: false

  # --- AST helpers ---

  defp find_nodes(%{"kind" => kind, "children" => children} = node, target_kind) do
    current = if kind == target_kind, do: [node], else: []
    current ++ Enum.flat_map(children, &find_nodes(&1, target_kind))
  end

  defp find_nodes(%{"kind" => kind} = node, target_kind) do
    if kind == target_kind, do: [node], else: []
  end

  defp find_nodes(_, _), do: []
end
