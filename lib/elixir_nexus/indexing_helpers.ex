defmodule ElixirNexus.IndexingHelpers do
  @moduledoc """
  Shared helpers for the indexing pipeline (Indexer single-file path and Broadway bulk path).
  Provides file processing, path normalization, embedding, and Qdrant storage.
  """
  require Logger

  @batch_size 96

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

  @doc """
  Map a file extension to its language atom, or `:unknown` if unsupported.

  Used for surfacing a per-language file count in the reindex response so users
  can confirm Astro/Rust/Swift weren't silently skipped.
  """
  def language_for_extension(ext) do
    cond do
      ext in @elixir_extensions -> :elixir
      Map.has_key?(@polyglot_extensions, ext) -> Map.fetch!(@polyglot_extensions, ext)
      true -> :unknown
    end
  end

  @doc """
  Group a list of file paths by language and return `[%{lang: atom, file_count: integer}]`,
  sorted by descending file_count. Files with unrecognized extensions are excluded.
  """
  def count_languages(files) do
    files
    |> Enum.group_by(fn path -> language_for_extension(Path.extname(path)) end)
    |> Map.delete(:unknown)
    |> Enum.map(fn {lang, paths} -> %{lang: lang, file_count: length(paths)} end)
    |> Enum.sort_by(& &1.file_count, :desc)
  end

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
    "views",
    # Go entrypoints (main packages)
    "cmd",
    # Go internal packages (private to the module)
    "internal",
    # Go shared packages
    "pkg"
  ]

  @doc """
  Detect indexable source directories under a base path.

  Default (inclusive-first): returns `[base_path]` and lets `IgnoreFilter` +
  extension filters decide what to skip. Repos that don't follow `lib/`/`src/`
  conventions (e.g. `Source/`, `cmd/`, naked file roots) are no longer
  silently skipped.

  Opt-in curated mode (`NEXUS_INDEX_STRATEGY=curated`): scans for conventional
  source dirs (`lib`, `src`, `app`, …) at depth 1, then depth 2 for monorepos,
  falling back to `[base_path]`. Useful for very large monorepos where
  pre-pruning to known roots is faster than a full walk.
  """
  def detect_indexable_dirs(base_path) do
    case System.get_env("NEXUS_INDEX_STRATEGY") do
      "curated" -> curated_or_fallback(base_path)
      _ -> [base_path]
    end
  end

  defp curated_or_fallback(base_path) do
    top_level =
      @indexable_dirs
      |> Enum.map(&Path.join(base_path, &1))
      |> Enum.filter(&File.dir?/1)

    if top_level != [] do
      top_level
    else
      second_level = monorepo_source_dirs(base_path)
      if second_level != [], do: second_level, else: [base_path]
    end
  end

  defp monorepo_source_dirs(base_path) do
    case File.ls(base_path) do
      {:ok, entries} ->
        entries
        |> Enum.flat_map(fn child ->
          child_path = Path.join(base_path, child)

          if File.dir?(child_path) and not String.starts_with?(child, ".") do
            @indexable_dirs
            |> Enum.map(&Path.join(child_path, &1))
            |> Enum.filter(&File.dir?/1)
          else
            []
          end
        end)

      {:error, _} ->
        []
    end
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
    sub_batch_concurrency = sub_batch_concurrency()

    Logger.info(
      "Embedding and storing #{length(chunks)} chunks in batches of #{@batch_size} " <>
        "(sub-batch concurrency: #{sub_batch_concurrency})..."
    )

    try do
      texts = Enum.map(chunks, &ElixirNexus.Chunker.prepare_for_embedding/1)
      ElixirNexus.TFIDFEmbedder.update_vocabulary(texts)
      keyword_texts = Enum.map(chunks, &ElixirNexus.Chunker.prepare_for_keywords/1)

      chunks
      |> Enum.zip(texts)
      |> Enum.zip(keyword_texts)
      |> Enum.chunk_every(@batch_size)
      |> Task.async_stream(&process_sub_batch/1,
        max_concurrency: sub_batch_concurrency,
        ordered: false,
        timeout: :infinity,
        on_timeout: :kill_task
      )
      |> Stream.run()

      duration_ms = System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)
      :telemetry.execute([:nexus, :embed_and_store], %{duration_ms: duration_ms, chunk_count: length(chunks)}, %{})
    rescue
      e -> Logger.error("Exception during embedding: #{inspect(e)}")
    end
  end

  # Embed + sparse-vectorize + Qdrant upsert for one sub-batch (≤ @batch_size chunks).
  # Runs inside a Task spawned by embed_and_store/1 so multiple sub-batches per
  # Broadway batch can hit Ollama and Qdrant concurrently.
  defp process_sub_batch(batch) do
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
  end

  # Configurable sub-batch parallelism. Default 2 — empirically the largest
  # value that didn't regress Ollama timeouts. Combined with Broadway's
  # `embed_and_store.concurrency: 2` that's up to 4 simultaneous Ollama
  # batches. Pushing higher (e.g. 4 sub × 2 Broadway = 8) reproduces the
  # v1.4.6 regression where Ollama hangs and every request hits the 180s
  # recv_timeout. Tune via `config :elixir_nexus, :embed_sub_batch_concurrency, N`.
  defp sub_batch_concurrency do
    Application.get_env(:elixir_nexus, :embed_sub_batch_concurrency, 2)
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
