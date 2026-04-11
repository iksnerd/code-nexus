defmodule ElixirNexus.Parsers.GoExtractor do
  @moduledoc """
  Entity extractor for Go ASTs from tree-sitter.
  Extracts functions, methods, type declarations (structs/interfaces),
  call expressions, and import declarations.
  """

  alias ElixirNexus.CodeSchema
  alias ElixirNexus.Parsers.Go.{Entities, ImportsPackage}

  @doc "Extract code entities from a tree-sitter AST."
  def extract_entities(file_path, ast, source) do
    declarations =
      ast
      |> Entities.walk_ast([])
      |> Enum.map(&Entities.to_code_schema(file_path, &1, source))
      |> Enum.reject(&is_nil/1)

    imports = ImportsPackage.extract_imports(ast)
    package_name = ImportsPackage.extract_package_name(ast)

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
      |> Enum.filter(&Entities.exported?/1)

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
            calls: ImportsPackage.extract_imported_package_names(ast),
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

  # Keep these delegations for backward compat (called from tests)
  @doc false
  defdelegate extract_imports(ast), to: ImportsPackage
end
