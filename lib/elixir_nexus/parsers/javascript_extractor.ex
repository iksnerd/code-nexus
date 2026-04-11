defmodule ElixirNexus.Parsers.JavaScriptExtractor do
  @moduledoc """
  Entity extractor for JavaScript/TypeScript ASTs from tree-sitter.
  Extracts functions, classes, methods, arrow functions, imports, and exports.
  """

  alias ElixirNexus.CodeSchema
  alias ElixirNexus.Parsers.JavaScript.{Entities, ImportsExports}

  @doc "Extract code entities from a tree-sitter AST."
  def extract_entities(file_path, ast, source) do
    declarations =
      ast
      |> Entities.walk_ast([])
      |> Enum.map(&Entities.to_code_schema(file_path, &1, source))
      |> Enum.reject(&is_nil/1)

    imports = ImportsExports.extract_imports(ast)
    exports = ImportsExports.extract_exports(ast)
    directive = ImportsExports.extract_directive(source)

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
            calls: ImportsExports.extract_imported_names(ast),
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

  # Keep these delegations for backward compat (called from tests)
  @doc false
  defdelegate extract_imports(ast), to: ImportsExports
  @doc false
  defdelegate extract_exports(ast), to: ImportsExports
end
