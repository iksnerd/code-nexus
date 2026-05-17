defmodule ElixirNexus.Parsers.GenericExtractor do
  @moduledoc """
  Generic entity extractor for tree-sitter ASTs.
  Works across languages by matching common AST node patterns
  (function_definition, class_definition, method_definition, etc.).
  Used as fallback when no language-specific extractor exists.
  """

  alias ElixirNexus.CodeSchema

  @definition_kinds ~w(
    function_definition function_declaration function_item
    method_definition method_declaration
    class_definition class_declaration
    struct_item struct_declaration
    interface_declaration type_declaration
    impl_item module_definition
    method singleton_method class module
    object_declaration property_declaration
    protocol_declaration extension_declaration init_declaration
  )

  @doc "Extract code entities from a tree-sitter AST."
  def extract_entities(file_path, ast, source) do
    language = detect_language_from_path(file_path)

    ast
    |> walk_ast([])
    |> Enum.map(&to_code_schema(file_path, &1, source, language))
    |> Enum.reject(&is_nil/1)
  end

  @extension_atoms %{
    ".go" => :go,
    ".rs" => :rust,
    ".java" => :java,
    ".rb" => :ruby,
    ".c" => :c,
    ".cpp" => :cpp,
    ".cs" => :csharp,
    ".swift" => :swift,
    ".kt" => :kotlin,
    ".scala" => :scala,
    ".lua" => :lua,
    ".php" => :php,
    ".r" => :r,
    ".sh" => :shell,
    ".zig" => :zig,
    ".dart" => :dart,
    ".haskell" => :haskell,
    ".hs" => :haskell,
    ".ml" => :ocaml,
    ".clj" => :clojure
  }

  defp detect_language_from_path(path) do
    Map.get(@extension_atoms, Path.extname(path), :unknown)
  end

  defp walk_ast(%{"kind" => kind, "children" => children} = node, acc) do
    acc = if kind in @definition_kinds, do: [node | acc], else: acc
    Enum.reduce(children, acc, &walk_ast/2)
  end

  defp walk_ast(%{"kind" => kind} = node, acc) do
    if kind in @definition_kinds, do: [node | acc], else: acc
  end

  defp walk_ast(_, acc), do: acc

  defp to_code_schema(file_path, node, source, language) do
    kind = node["kind"]
    name = node["name"]
    start_line = (node["start_row"] || 0) + 1
    end_line = (node["end_row"] || 0) + 1

    entity_type =
      cond do
        String.contains?(kind, "class") -> :class
        String.contains?(kind, "method") -> :method
        String.contains?(kind, "struct") -> :struct
        String.contains?(kind, "interface") -> :interface
        String.contains?(kind, "impl") -> :module
        String.contains?(kind, "module") -> :module
        String.contains?(kind, "property") -> :variable
        String.contains?(kind, "function") -> :function
        true -> :function
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
        visibility: :public,
        calls: extract_calls(node),
        is_a: extract_imports(node),
        contains: extract_contains(node),
        language: language
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
    |> Enum.filter(&String.contains?(&1["kind"] || "", "parameter"))
    |> Enum.flat_map(fn params ->
      (params["children"] || [])
      |> Enum.filter(&(&1["kind"] == "identifier"))
      |> Enum.map(&(&1["text"] || &1["name"] || ""))
    end)
  end

  defp extract_params(_), do: []

  defp extract_calls(%{"children" => children}) do
    children
    |> Enum.flat_map(&find_calls/1)
    |> Enum.uniq()
  end

  defp extract_calls(_), do: []

  defp find_calls(%{"kind" => kind, "name" => name}) when is_binary(name) do
    if String.contains?(kind, "call"), do: [name], else: []
  end

  defp find_calls(%{"children" => children}), do: Enum.flat_map(children, &find_calls/1)
  defp find_calls(_), do: []

  @import_kinds ~w(
    import_declaration import_statement use_declaration
    include_directive package_clause
  )

  defp extract_imports(%{"children" => children}) do
    children
    |> Enum.flat_map(&find_imports/1)
    |> Enum.uniq()
  end

  defp extract_imports(_), do: []

  defp find_imports(%{"kind" => kind} = node) when kind in @import_kinds do
    extract_import_path(node)
  end

  defp find_imports(%{"children" => children}), do: Enum.flat_map(children, &find_imports/1)
  defp find_imports(_), do: []

  defp extract_import_path(%{"children" => children}) do
    children
    |> Enum.filter(
      &(&1["kind"] in [
          "identifier",
          "qualified_identifier",
          "scoped_identifier",
          "string",
          "string_literal",
          "interpreted_string_literal",
          "package_identifier",
          "type_identifier"
        ])
    )
    |> Enum.map(fn node ->
      node["text"] || node["name"] || ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.trim(&1, "\""))
  end

  defp extract_import_path(_), do: []

  defp extract_contains(%{"children" => children}) do
    children
    |> Enum.filter(&(&1["kind"] in @definition_kinds))
    |> Enum.map(&(&1["name"] || ""))
    |> Enum.reject(&(&1 == ""))
  end

  defp extract_contains(_), do: []
end
