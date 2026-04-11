defmodule ElixirNexus.Parsers.JavaScriptExtractor do
  @moduledoc """
  Entity extractor for JavaScript/TypeScript ASTs from tree-sitter.
  Extracts functions, classes, methods, arrow functions, imports, and exports.
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
    exports = extract_exports(ast)
    directive = extract_directive(source)

    # Enrich declarations with import/export info
    exported_names = MapSet.new(exports)

    declarations =
      Enum.map(declarations, fn entity ->
        cond do
          MapSet.member?(exported_names, entity.name) ->
            %{entity | visibility: :public, is_a: Enum.uniq(entity.is_a ++ imports)}

          true ->
            %{entity | is_a: Enum.uniq(entity.is_a ++ imports)}
        end
      end)

    # Create a file-level module entity if there are imports, exports, or a directive.
    # For barrel files (index.ts/index.js), use parent directory name as module name.
    file_entity =
      if imports != [] or exports != [] or directive != nil do
        basename = Path.basename(file_path, Path.extname(file_path))

        module_name =
          if basename == "index" do
            Path.dirname(file_path) |> Path.basename()
          else
            basename
          end

        # Tag the directive in is_a so it flows into Qdrant and is searchable.
        # e.g. "directive:use-client" or "directive:use-server"
        directive_tag = if directive, do: ["directive:#{directive}"], else: []

        [
          %CodeSchema{
            file_path: file_path,
            entity_type: :module,
            name: module_name,
            content: if(directive, do: ~s("#{directive}"), else: ""),
            start_line: 1,
            end_line: 1,
            parameters: [],
            visibility: :public,
            calls: extract_imported_names(ast),
            is_a: imports ++ directive_tag,
            contains: exports,
            language: :javascript
          }
        ]
      else
        []
      end

    file_entity ++ declarations
  end

  defp walk_ast(%{"kind" => kind, "children" => children} = node, acc) do
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
          return_early = collect_export_declaration(node, acc)
          return_early

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

  defp walk_ast(%{"kind" => kind} = node, acc) do
    case kind do
      "function_declaration" -> [node | acc]
      "method_definition" -> [node | acc]
      "class_declaration" -> [node | acc]
      "interface_declaration" -> [node | acc]
      _ -> acc
    end
  end

  defp walk_ast(_, acc), do: acc

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
  # Standalone arrow functions (callbacks, IIFEs) are captured via their parent declaration.
  defp has_name_context?(%{"name" => name}) when is_binary(name) and name != "", do: true
  defp has_name_context?(%{"kind" => "arrow_function"}), do: false
  defp has_name_context?(_), do: false

  defp to_code_schema(file_path, node, source) do
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
        calls: extract_calls(node),
        is_a: extract_extends(node),
        contains: extract_contains(node),
        language: :javascript
      }
    end
  end

  defp extract_name_from_fields(%{"fields" => %{"name" => name}}), do: name
  defp extract_name_from_fields(_), do: nil

  # Extract name from `const Foo = ...` style declarations
  defp extract_name_from_declarator(%{"children" => children}) do
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

  defp extract_name_from_declarator(_), do: nil

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

  # Detect "use client" / "use server" React/Next.js directives at the top of the file.
  # Returns "use-client", "use-server", or nil. Only checks the first 5 lines.
  defp extract_directive(source) do
    source
    |> String.split("\n", parts: 6)
    |> Enum.take(5)
    |> Enum.find_value(nil, fn line ->
      case String.trim(line) do
        ~s("use client") -> "use-client"
        "'use client'" -> "use-client"
        ~s("use server") -> "use-server"
        "'use server'" -> "use-server"
        _ -> nil
      end
    end)
  end

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

  defp extract_calls(%{"children" => children}) do
    children
    |> Enum.flat_map(&find_calls/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp extract_calls(_), do: []

  # call_expression with a name field (e.g. tree-sitter provides it directly)
  defp find_calls(%{"kind" => "call_expression", "name" => name}) when is_binary(name) and name != "" do
    [name]
  end

  # call_expression — extract the callee name, recurse into arguments (not callee) to avoid duplicates
  defp find_calls(%{"kind" => "call_expression", "children" => children}) do
    callee_node =
      Enum.find(children, fn child ->
        child["kind"] in ["identifier", "member_expression", "call_expression"]
      end)

    callee_name = extract_callee_name(callee_node)

    # Only recurse into non-callee children (arguments, etc.) to avoid duplicate extraction
    non_callee = if callee_node, do: children -- [callee_node], else: children
    argument_calls = Enum.flat_map(non_callee, &find_calls/1)

    # Recurse into the callee chain for nested calls (e.g., db.collection().doc().set())
    callee_chain_calls = find_calls_in_callee(callee_node)

    all_calls = argument_calls ++ callee_chain_calls

    case callee_name do
      nil -> all_calls
      name -> [name | all_calls]
    end
  end

  defp find_calls(%{"kind" => "call_expression"}), do: []

  # new Foo() expressions
  defp find_calls(%{"kind" => "new_expression", "children" => children}) do
    callee =
      children
      |> Enum.find(&(&1["kind"] == "identifier"))
      |> then(fn
        %{"text" => t} when is_binary(t) -> t
        %{"name" => n} when is_binary(n) -> n
        _ -> nil
      end)

    rest = Enum.flat_map(children, &find_calls/1)
    if callee, do: [callee | rest], else: rest
  end

  # member_expression — recurse to find chained calls (e.g., db.collection().doc().set())
  defp find_calls(%{"kind" => "member_expression", "children" => children}) do
    Enum.flat_map(children, &find_calls/1)
  end

  # JSX self-closing elements: <Button />, <Card /> → treat as calls to the component
  defp find_calls(%{"kind" => kind, "children" => children})
       when kind in ["jsx_self_closing_element", "jsx_opening_element"] do
    tag_name =
      children
      |> Enum.find(&(&1["kind"] == "identifier"))
      |> then(fn
        %{"text" => t} when is_binary(t) -> t
        %{"name" => n} when is_binary(n) -> n
        _ -> nil
      end)

    # Only track PascalCase components — skip intrinsic HTML elements (div, span, etc.)
    rest = Enum.flat_map(children, &find_calls/1)

    if tag_name && Regex.match?(~r/^[A-Z]/, tag_name) do
      [tag_name | rest]
    else
      rest
    end
  end

  # Recurse into other nodes with children
  defp find_calls(%{"children" => children}), do: Enum.flat_map(children, &find_calls/1)
  defp find_calls(_), do: []

  # Recurse into callee chain to find nested call_expressions without double-counting
  defp find_calls_in_callee(%{"kind" => "member_expression", "children" => children}) do
    children
    |> Enum.filter(&(&1["kind"] == "call_expression"))
    |> Enum.flat_map(&find_calls/1)
  end

  defp find_calls_in_callee(%{"kind" => "call_expression"} = node), do: find_calls(node)
  defp find_calls_in_callee(_), do: []

  # Extract a readable name from a callee node
  defp extract_callee_name(%{"kind" => "identifier", "text" => text}) when is_binary(text), do: text
  defp extract_callee_name(%{"kind" => "identifier", "name" => name}) when is_binary(name), do: name

  defp extract_callee_name(%{"kind" => "member_expression", "children" => children}) do
    # For simple member expressions like "db.collection", join identifiers
    # For chained calls like "db.collection('x').doc", extract just the property (last identifier)
    has_call_child = Enum.any?(children, &(&1["kind"] == "call_expression"))

    if has_call_child do
      # Chained: foo().bar — extract just "bar" (the property being accessed)
      children
      |> Enum.find(&(&1["kind"] == "property_identifier"))
      |> then(fn
        %{"text" => t} when is_binary(t) -> t
        %{"name" => n} when is_binary(n) -> n
        _ -> nil
      end)
    else
      # Simple: db.collection — join all identifiers
      parts =
        children
        |> Enum.filter(&(&1["kind"] in ["identifier", "property_identifier"]))
        |> Enum.map(&(&1["text"] || &1["name"] || ""))
        |> Enum.reject(&(&1 == ""))

      case parts do
        [] -> nil
        _ -> Enum.join(parts, ".")
      end
    end
  end

  defp extract_callee_name(%{"kind" => "member_expression", "text" => text}) when is_binary(text), do: text
  defp extract_callee_name(_), do: nil

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

  # --- Import extraction ---

  @doc false
  def extract_imports(ast) do
    ast
    |> find_nodes("import_statement")
    |> Enum.map(&extract_import_source/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp extract_import_source(%{"children" => children}) do
    children
    |> Enum.find(&(&1["kind"] == "string" || &1["kind"] == "string_fragment"))
    |> extract_string_value()
  end

  defp extract_import_source(_), do: nil

  # Extract text from a string node (may have string_fragment child)
  defp extract_string_value(%{"kind" => "string_fragment", "text" => text}), do: clean_string(text)
  defp extract_string_value(%{"kind" => "string", "text" => text}) when text != "", do: clean_string(text)

  defp extract_string_value(%{"kind" => "string", "children" => children}) do
    case Enum.find(children, &(&1["kind"] == "string_fragment")) do
      %{"text" => text} -> clean_string(text)
      _ -> nil
    end
  end

  defp extract_string_value(_), do: nil

  defp clean_string(text), do: text |> String.trim("\"") |> String.trim("'")

  # Extract imported names (identifiers from import statements) for calls graph
  defp extract_imported_names(ast) do
    ast
    |> find_nodes("import_statement")
    |> Enum.flat_map(&extract_import_identifiers/1)
    |> Enum.uniq()
  end

  defp extract_import_identifiers(%{"children" => children}) do
    children
    |> Enum.flat_map(fn child ->
      case child["kind"] do
        "import_clause" ->
          find_identifiers(child)

        "import_specifier" ->
          case child do
            %{"name" => name} when is_binary(name) -> [name]
            _ -> find_identifiers(child)
          end

        "named_imports" ->
          find_identifiers(child)

        "identifier" ->
          [child["text"] || child["name"] || ""]

        _ ->
          []
      end
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp extract_import_identifiers(_), do: []

  defp find_identifiers(%{"children" => children}) do
    Enum.flat_map(children, fn child ->
      case child["kind"] do
        "identifier" ->
          name = child["text"] || child["name"] || ""
          if name != "", do: [name], else: []

        "import_specifier" ->
          case child do
            %{"name" => name} when is_binary(name) -> [name]
            _ -> find_identifiers(child)
          end

        _ ->
          if Map.has_key?(child, "children"), do: find_identifiers(child), else: []
      end
    end)
  end

  defp find_identifiers(_), do: []

  # --- Export extraction ---

  @doc false
  def extract_exports(ast) do
    ast
    |> find_nodes("export_statement")
    |> Enum.flat_map(&extract_export_names/1)
    |> Enum.uniq()
  end

  defp extract_export_names(%{"children" => children}) do
    Enum.flat_map(children, fn child ->
      case child["kind"] do
        "function_declaration" ->
          name = child["name"] || extract_name_from_fields(child)
          if name, do: [name], else: []

        "class_declaration" ->
          name = child["name"] || extract_name_from_fields(child)
          if name, do: [name], else: []

        "lexical_declaration" ->
          [extract_name_from_declarator(child)] |> Enum.reject(&is_nil/1)

        "variable_declaration" ->
          [extract_name_from_declarator(child)] |> Enum.reject(&is_nil/1)

        "interface_declaration" ->
          name = child["name"] || extract_name_from_fields(child)
          if name, do: [name], else: []

        "type_alias_declaration" ->
          name = child["name"] || extract_name_from_fields(child)
          if name, do: [name], else: []

        "export_clause" ->
          find_identifiers(child)

        # default export
        "identifier" ->
          name = child["text"] || child["name"] || ""
          if name != "", do: [name], else: []

        _ ->
          []
      end
    end)
  end

  defp extract_export_names(_), do: []

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
