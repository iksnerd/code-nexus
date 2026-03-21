defmodule ElixirNexus.EmbeddingModel do
  @moduledoc """
  Dense embedding via Bumblebee sentence-transformers/all-MiniLM-L6-v2.
  Thin wrapper around Nx.Serving — no GenServer needed.
  """
  require Logger

  @model_id "sentence-transformers/all-MiniLM-L6-v2"
  @serving_name ElixirNexus.EmbeddingServing

  @doc "Returns the Nx.Serving child spec for the supervision tree, or nil if model can't load."
  def serving_child_spec do
    Logger.info("Loading Bumblebee model: #{@model_id}")

    with {:ok, model_info} <- Bumblebee.load_model({:hf, @model_id}),
         {:ok, tokenizer} <- Bumblebee.load_tokenizer({:hf, @model_id}) do
      serving =
        Bumblebee.Text.text_embedding(model_info, tokenizer,
          output_pool: :mean_pooling,
          output_attribute: :hidden_state,
          compile: [batch_size: 32, sequence_length: 128],
          defn_options: [compiler: EXLA]
        )

      {Nx.Serving, serving: serving, name: @serving_name, batch_size: 32, batch_timeout: 50}
    else
      {:error, reason} ->
        Logger.warning("Bumblebee model unavailable: #{inspect(reason)}. Using TF-IDF fallback.")
        nil
    end
  rescue
    e ->
      Logger.warning("Error loading Bumblebee model: #{inspect(e)}. Using TF-IDF fallback.")
      nil
  end

  @doc "Embed a single text. Returns {:ok, [float]} or {:error, reason}."
  def embed(text) when is_binary(text) do
    if available?() do
      try do
        result = Nx.Serving.batched_run(@serving_name, text)
        {:ok, result.embedding |> Nx.to_flat_list()}
      rescue
        e -> {:error, e}
      end
    else
      {:error, :model_unavailable}
    end
  end

  @doc "Embed a batch of texts. Returns {:ok, [[float]]} or {:error, reason}."
  def embed_batch(texts) when is_list(texts) do
    if available?() do
      try do
        # Fire all texts concurrently — Nx.Serving batches them automatically
        embeddings =
          texts
          |> Task.async_stream(
            fn text ->
              result = Nx.Serving.batched_run(@serving_name, text)
              result.embedding |> Nx.to_flat_list()
            end,
            max_concurrency: System.schedulers_online(),
            timeout: 30_000,
            ordered: true
          )
          |> Enum.map(fn
            {:ok, embedding} -> embedding
            {:exit, reason} ->
              Logger.warning("Embedding task failed: #{inspect(reason)}")
              List.duplicate(0.0, 384)
          end)

        {:ok, embeddings}
      rescue
        e -> {:error, e}
      end
    else
      {:error, :model_unavailable}
    end
  end

  @doc "Check if the Bumblebee serving is running."
  def available? do
    Process.whereis(@serving_name) != nil
  end
end
