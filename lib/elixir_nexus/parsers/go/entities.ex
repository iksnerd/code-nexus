defmodule ElixirNexus.Parsers.Go.Entities do
  @moduledoc "Entity extraction from Go tree-sitter ASTs."

  alias ElixirNexus.CodeSchema
  alias ElixirNexus.Parsers.Go.Calls

  @doc "Walk a tree-sitter AST and collect declaration nodes."
  def walk_ast(%{"kind" => kind, "children" => children} = node, acc) do
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

  def walk_ast(%{"kind" => kind} = node, acc) do
    case kind do
      "function_declaration" -> [node | acc]
      "method_declaration" -> [node | acc]
      _ -> acc
    end
  end

  def walk_ast(_, acc), do: acc

  @doc "Convert a declaration AST node to a CodeSchema struct."
  def to_code_schema(file_path, node, source) do
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

  @doc "True if the given Go identifier name is exported (starts with uppercase)."
  def exported?(name) when is_binary(name), do: go_visibility(name) == :public
  def exported?(_), do: false

  @doc "Determine visibility based on Go capitalisation convention."
  def go_visibility(name) when is_binary(name) do
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

  def go_visibility(_), do: :private

  # type_declaration contains one or more type_spec children
  defp collect_type_specs(%{"children" => children}, acc) do
    children
    |> Enum.filter(&(&1["kind"] == "type_spec"))
    |> Enum.reduce(acc, fn spec, inner_acc -> [spec | inner_acc] end)
  end

  defp collect_type_specs(_, acc), do: acc

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
        calls: Calls.extract_calls(node),
        is_a: [],
        contains: [],
        language: :go
      }
    end
  end

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

  defp extract_content(source, start_line, end_line) when start_line > 0 and end_line > 0 do
    source
    |> String.split("\n")
    |> Enum.slice((start_line - 1)..(end_line - 1))
    |> Enum.join("\n")
  end

  defp extract_content(_, _, _), do: ""
end
