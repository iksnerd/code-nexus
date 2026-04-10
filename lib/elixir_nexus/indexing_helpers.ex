defmodule ElixirNexus.IndexingHelpers do
  @moduledoc """
  Shared helpers for the indexing pipeline (Indexer single-file path and Broadway bulk path).
  Provides file processing, path normalization, embedding, and Qdrant storage.
  """
  require Logger

  @batch_size 32

  @elixir_extensions [".ex", ".exs"]
  @polyglot_extensions %{
    ".js" => :javascript,
    ".jsx" => :javascript,
    ".ts" => :typescript,
    ".tsx" => :tsx,
    ".py" => :python,
    ".go" => :go,
    ".rs" => :rust,
    ".java" => :java,
    ".rb" => :ruby
  }

  def elixir_extensions, do: @elixir_extensions
  def polyglot_extensions, do: @polyglot_extensions
  def all_indexable_extensions, do: @elixir_extensions ++ Map.keys(@polyglot_extensions)

  @indexable_dirs [
    # Elixir/Ruby
    "lib",
    # Next.js/TypeScript/Java/Go/Rust
    "src",
    # Next.js App Router / Rails
    "app",
    # Next.js Pages Router
    "pages",
    # React
    "components",
    # Common JS/TS
    "utils",
    # Monorepo
    "packages",
    # Service layer
    "services",
    # Infrastructure/adapters
    "infrastructure",
    # Data access layer
    "repositories",
    # Domain core
    "core",
    # React hooks / Git hooks
    "hooks",
    # API routes
    "api",
    # Python/generic
    "modules",
    # MVC controllers
    "controllers",
    # MVC models
    "models",
    # MVC views
    "views"
  ]

  @doc "Detect indexable source directories under a base path. Falls back to base path itself."
  def detect_indexable_dirs(base_path) do
    found =
      @indexable_dirs
      |> Enum.map(&Path.join(base_path, &1))
      |> Enum.filter(&File.dir?/1)

    if found == [], do: [base_path], else: found
  end

  @doc "Parse a source file into chunks."
  def process_file(file_path) do
    normalized_path = normalize_path(file_path)
    ext = Path.extname(file_path)

    cond do
      ext in @elixir_extensions ->
        with {:ok, entities} <- ElixirNexus.Parser.parse_file(normalized_path),
             chunks = ElixirNexus.Chunker.chunk_entities(entities) do
          {:ok, Enum.map(chunks, &Map.put(&1, :language, :elixir))}
        end

      Map.has_key?(@polyglot_extensions, ext) ->
        language = Map.get(@polyglot_extensions, ext)

        case parse_with_tree_sitter(normalized_path, language) do
          {:ok, chunks} -> {:ok, chunks}
          {:error, _} -> {:ok, []}
        end

      true ->
        {:ok, []}
    end
  end

  @doc "Normalize a file path to be relative to CWD when possible."
  def normalize_path(path) do
    abs_path = Path.expand(path)
    cwd = File.cwd!()

    case String.trim_leading(abs_path, cwd <> "/") do
      ^abs_path -> abs_path
      relative -> relative
    end
  end

  @doc "Embed and store chunks in Qdrant in batches."
  def embed_and_store(chunks) when chunks == [], do: :ok

  def embed_and_store(chunks) do
    start_time = System.monotonic_time()
    Logger.info("Embedding and storing #{length(chunks)} chunks in batches of #{@batch_size}...")

    try do
      texts = Enum.map(chunks, &ElixirNexus.Chunker.prepare_for_embedding/1)
      ElixirNexus.TFIDFEmbedder.update_vocabulary(texts)
      keyword_texts = Enum.map(chunks, &ElixirNexus.Chunker.prepare_for_keywords/1)

      chunks
      |> Enum.zip(texts)
      |> Enum.zip(keyword_texts)
      |> Enum.chunk_every(@batch_size)
      |> Enum.each(fn batch ->
        batch_texts = Enum.map(batch, fn {{_, text}, _} -> text end)
        batch_chunks = Enum.map(batch, fn {{chunk, _}, _} -> chunk end)
        batch_kw_texts = Enum.map(batch, fn {{_, _}, kw} -> kw end)

        embeddings = get_batch_embeddings(batch_texts)
        sparse_vectors = ElixirNexus.TFIDFEmbedder.sparse_vector_batch(batch_kw_texts)

        points =
          batch_chunks
          |> Enum.zip(embeddings)
          |> Enum.zip(sparse_vectors)
          |> Enum.map(fn {{chunk, embedding}, sparse_vec} ->
            chunk_id = chunk.id |> String.slice(0..15) |> String.to_integer(16)

            %{
              "id" => chunk_id,
              "vector" => %{
                "semantic" => embedding,
                "keywords" => sparse_vec
              },
              "payload" => %{
                "file_path" => chunk.file_path,
                "entity_type" => Atom.to_string(chunk.entity_type),
                "name" => chunk.name,
                "start_line" => chunk.start_line,
                "end_line" => chunk.end_line,
                "module_path" => chunk.module_path,
                "visibility" => chunk.visibility && Atom.to_string(chunk.visibility),
                "parameters" => chunk.parameters,
                "calls" => ElixirNexus.Search.filter_ast_noise(chunk.calls),
                "is_a" => ElixirNexus.Search.filter_ast_noise(chunk.is_a),
                "contains" => ElixirNexus.Search.filter_ast_noise(chunk.contains),
                "content" => chunk.content,
                "language" => chunk[:language] && Atom.to_string(chunk[:language])
              }
            }
          end)

        case ElixirNexus.QdrantClient.upsert_points(points) do
          {:ok, _} ->
            Logger.debug("Stored batch of #{length(points)} chunks")

          {:error, reason} ->
            Logger.error("Failed to store batch of #{length(points)} chunks: #{inspect(reason)}")
            :telemetry.execute([:nexus, :qdrant, :upsert_error], %{batch_size: length(points)}, %{reason: reason})
        end
      end)

      duration_ms = System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)
      :telemetry.execute([:nexus, :embed_and_store], %{duration_ms: duration_ms, chunk_count: length(chunks)}, %{})
    rescue
      e -> Logger.error("Exception during embedding: #{inspect(e)}")
    end
  end

  @doc "Get embeddings for a batch of texts, falling back to TF-IDF then zeros."
  def get_batch_embeddings(texts) do
    case ElixirNexus.EmbeddingModel.embed_batch(texts) do
      {:ok, embeddings} ->
        embeddings

      {:error, ollama_reason} ->
        Logger.debug("Ollama embedding failed: #{inspect(ollama_reason)}, using TF-IDF")
        {:ok, embeddings} = ElixirNexus.TFIDFEmbedder.embed_batch(texts)
        embeddings
    end
  end

  defp parse_with_tree_sitter(file_path, language) do
    if Code.ensure_loaded?(ElixirNexus.TreeSitterParser) do
      ElixirNexus.TreeSitterParser.parse_and_extract(file_path, language)
    else
      {:error, :tree_sitter_not_available}
    end
  end
end
