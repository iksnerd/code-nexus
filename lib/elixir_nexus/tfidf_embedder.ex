defmodule ElixirNexus.TFIDFEmbedder do
  @moduledoc """
  TF-IDF based embedder with both dense (768-dim) and sparse vector support.
  Dense vectors use feature hashing. Sparse vectors use Qdrant's sparse format
  for native keyword search via RRF fusion.

  IDF map is stored in ETS with read_concurrency for fast concurrent lookups.
  Vocabulary updates go through GenServer to serialize writes.
  """
  use GenServer
  require Logger

  @vector_size 768
  @idf_table :nexus_tfidf_idf

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def embed(text) when is_binary(text) do
    embedding = text_to_embedding(text)
    {:ok, embedding}
  end

  def embed_batch(texts) when is_list(texts) do
    embeddings = Enum.map(texts, &text_to_embedding/1)
    {:ok, embeddings}
  end

  def update_vocabulary(texts) when is_list(texts) do
    GenServer.call(__MODULE__, {:update_vocabulary, texts}, :infinity)
  end

  def vocab_size do
    case :ets.info(@idf_table, :size) do
      :undefined -> 0
      n -> n
    end
  end

  @doc "Generate a sparse vector in Qdrant format: %{indices: [...], values: [...]}"
  def sparse_vector(text) when is_binary(text) do
    text_to_sparse(text)
  end

  @doc "Generate sparse vectors for a batch of texts."
  def sparse_vector_batch(texts) when is_list(texts) do
    Enum.map(texts, &text_to_sparse/1)
  end

  @impl true
  def init(_opts) do
    Logger.info("Initializing TF-IDF embedder (768-dim dense + sparse vectors)")
    :ets.new(@idf_table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{doc_count: 0, doc_freq: %{}}}
  end

  @impl true
  def handle_call({:update_vocabulary, texts}, _from, state) do
    new_state = update_idf(texts, state)
    Logger.info("Updated vocabulary: #{map_size(new_state.doc_freq)} unique words, #{new_state.doc_count} documents")
    {:reply, :ok, new_state}
  end

  defp update_idf(texts, state) do
    new_doc_count = state.doc_count + length(texts)

    new_doc_freq =
      Enum.reduce(texts, state.doc_freq, fn text, acc ->
        text
        |> tokenize()
        |> Enum.uniq()
        |> Enum.reduce(acc, fn word, df ->
          Map.update(df, word, 1, &(&1 + 1))
        end)
      end)

    # Batch insert IDF values into ETS for concurrent reads
    entries =
      Enum.map(new_doc_freq, fn {word, freq} ->
        {word, :math.log((new_doc_count + 1) / (freq + 1)) + 1.0}
      end)

    :ets.insert(@idf_table, entries)

    %{state | doc_count: new_doc_count, doc_freq: new_doc_freq}
  end

  # Read IDF from ETS — concurrent-safe, no GenServer call needed
  defp get_idf(word) do
    case :ets.lookup(@idf_table, word) do
      [{^word, idf}] -> idf
      [] -> 1.0
    end
  rescue
    _ -> 1.0
  end

  defp text_to_embedding(text) do
    words = tokenize(text)
    word_counts = Enum.frequencies(words)

    vector =
      Enum.reduce(word_counts, %{}, fn {word, count}, acc ->
        bucket = hash_word(word)
        tf = 1.0 + :math.log(count)
        idf = get_idf(word)
        score = tf * idf
        sign = hash_sign(word)
        Map.update(acc, bucket, score * sign, &(&1 + score * sign))
      end)

    dense =
      for i <- 0..(@vector_size - 1) do
        Map.get(vector, i, 0.0)
      end

    normalize_vector(dense)
  end

  defp text_to_sparse(text) do
    words = tokenize(text)
    word_counts = Enum.frequencies(words)

    entries =
      word_counts
      |> Enum.map(fn {word, count} ->
        bucket = hash_word(word)
        tf = 1.0 + :math.log(count)
        idf = get_idf(word)
        {bucket, tf * idf}
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {idx, vals} -> {idx, Enum.sum(vals)} end)
      |> Enum.sort_by(&elem(&1, 0))

    %{
      "indices" => Enum.map(entries, &elem(&1, 0)),
      "values" => Enum.map(entries, &elem(&1, 1))
    }
  end

  defp hash_word(word) do
    :erlang.phash2(word, @vector_size)
  end

  defp hash_sign(word) do
    case :erlang.phash2({word, :sign}, 2) do
      0 -> -1.0
      1 -> 1.0
    end
  end

  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9_]+/)
    |> Enum.reject(&(String.length(&1) < 2))
  end

  defp normalize_vector(vector) do
    magnitude = :math.sqrt(Enum.reduce(vector, 0.0, &(&1 * &1 + &2)))

    if magnitude > 0 do
      Enum.map(vector, &(&1 / magnitude))
    else
      vector
    end
  end
end
