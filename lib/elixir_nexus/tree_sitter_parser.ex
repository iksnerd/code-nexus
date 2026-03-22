defmodule ElixirNexus.TreeSitterParser do
  @moduledoc """
  Tree-sitter based polyglot parser via Rustler NIF.
  Parses source code into AST JSON, then delegates to language-specific extractors.
  """
  require Logger

  alias ElixirNexus.Parsers.{JavaScriptExtractor, PythonExtractor, GoExtractor, GenericExtractor}

  # Language detection by file extension
  @extension_map %{
    ".js" => :javascript,
    ".jsx" => :javascript,
    ".mjs" => :javascript,
    ".ts" => :typescript,
    ".tsx" => :tsx,
    ".py" => :python,
    ".go" => :go,
    ".rs" => :rust,
    ".java" => :java,
    ".rb" => :ruby,
    ".ex" => :elixir,
    ".exs" => :elixir
  }

  @doc "Detect language from file extension."
  def detect_language(file_path) do
    ext = Path.extname(file_path)
    Map.get(@extension_map, ext)
  end

  @doc "Parse a file and extract code entities."
  def parse_and_extract(file_path, language \\ nil) do
    language = language || detect_language(file_path)

    case File.read(file_path) do
      {:ok, source} ->
        case parse(to_string(language), source) do
          {:ok, ast_json} ->
            ast = Jason.decode!(ast_json)
            entities = extract_entities(file_path, language, ast, source)
            chunks = ElixirNexus.Chunker.chunk_entities(entities)
            {:ok, Enum.map(chunks, &Map.put(&1, :language, language))}

          {:error, reason} ->
            Logger.warning("Tree-sitter parse failed for #{file_path}: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_entities(file_path, language, ast, source) do
    extractor = get_extractor(language)
    extractor.extract_entities(file_path, ast, source)
  end

  defp get_extractor(:javascript), do: JavaScriptExtractor
  defp get_extractor(:typescript), do: JavaScriptExtractor
  defp get_extractor(:tsx), do: JavaScriptExtractor
  defp get_extractor(:python), do: PythonExtractor
  defp get_extractor(:go), do: GoExtractor
  defp get_extractor(_language), do: GenericExtractor

  # NIF placeholder — will be replaced by Rustler at compile time if native code is available
  defp parse(language, source) do
    if Code.ensure_loaded?(__MODULE__.Native) do
      __MODULE__.Native.parse(language, source)
    else
      {:error, :nif_not_loaded}
    end
  end
end

defmodule ElixirNexus.TreeSitterParser.Native do
  @moduledoc false
  use Rustler,
    otp_app: :elixir_nexus,
    crate: "tree_sitter_nif",
    skip_compilation?: true,
    load_from: {:elixir_nexus, "priv/native/tree_sitter_nif"}

  def parse(_language, _source), do: :erlang.nif_error(:nif_not_loaded)
end
