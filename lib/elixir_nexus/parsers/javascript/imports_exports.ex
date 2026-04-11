defmodule ElixirNexus.Parsers.JavaScript.ImportsExports do
  @moduledoc "Import, export, and directive extraction from JavaScript/TypeScript ASTs."

  alias ElixirNexus.Parsers.JavaScript.Entities

  @doc "Find all import source paths in an AST."
  def extract_imports(ast) do
    ast
    |> find_nodes("import_statement")
    |> Enum.map(&extract_import_source/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc "Find all exported names in an AST."
  def extract_exports(ast) do
    ast
    |> find_nodes("export_statement")
    |> Enum.flat_map(&extract_export_names/1)
    |> Enum.uniq()
  end

  @doc "Extract imported identifier names (for call graph edges)."
  def extract_imported_names(ast) do
    ast
    |> find_nodes("import_statement")
    |> Enum.flat_map(&extract_import_identifiers/1)
    |> Enum.uniq()
  end

  @doc """
  Detect "use client" / "use server" React/Next.js directives at the top of the file.
  Returns "use-client", "use-server", or nil. Only checks the first 5 lines.
  """
  def extract_directive(source) do
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

  defp extract_export_names(%{"children" => children}) do
    Enum.flat_map(children, fn child ->
      case child["kind"] do
        "function_declaration" ->
          name = child["name"] || Entities.extract_name_from_fields(child)
          if name, do: [name], else: []

        "class_declaration" ->
          name = child["name"] || Entities.extract_name_from_fields(child)
          if name, do: [name], else: []

        "lexical_declaration" ->
          [Entities.extract_name_from_declarator(child)] |> Enum.reject(&is_nil/1)

        "variable_declaration" ->
          [Entities.extract_name_from_declarator(child)] |> Enum.reject(&is_nil/1)

        "interface_declaration" ->
          name = child["name"] || Entities.extract_name_from_fields(child)
          if name, do: [name], else: []

        "type_alias_declaration" ->
          name = child["name"] || Entities.extract_name_from_fields(child)
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

  defp find_nodes(%{"kind" => kind, "children" => children} = node, target_kind) do
    current = if kind == target_kind, do: [node], else: []
    current ++ Enum.flat_map(children, &find_nodes(&1, target_kind))
  end

  defp find_nodes(%{"kind" => kind} = node, target_kind) do
    if kind == target_kind, do: [node], else: []
  end

  defp find_nodes(_, _), do: []
end
