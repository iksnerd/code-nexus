defmodule ElixirNexus.Parsers.Go.ImportsPackage do
  @moduledoc "Import path and package name extraction from Go tree-sitter ASTs."

  @doc "Find all import paths in a Go AST."
  def extract_imports(ast) do
    ast
    |> find_nodes("import_declaration")
    |> Enum.flat_map(&extract_import_paths/1)
    |> Enum.uniq()
  end

  @doc "Extract short package names from imports (e.g. 'net/http' → 'http')."
  def extract_imported_package_names(ast) do
    ast
    |> extract_imports()
    |> Enum.map(fn import_path ->
      # "fmt" -> "fmt", "net/http" -> "http", "github.com/foo/bar" -> "bar"
      import_path |> String.split("/") |> List.last() || import_path
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  @doc "Extract the package name from a Go file's package_clause."
  def extract_package_name(ast) do
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

  defp clean_string(text), do: text |> String.trim("\"") |> String.trim("'")

  defp find_nodes(%{"kind" => kind, "children" => children} = node, target_kind) do
    current = if kind == target_kind, do: [node], else: []
    current ++ Enum.flat_map(children, &find_nodes(&1, target_kind))
  end

  defp find_nodes(%{"kind" => kind} = node, target_kind) do
    if kind == target_kind, do: [node], else: []
  end

  defp find_nodes(_, _), do: []
end
