defmodule ElixirNexus.EmbeddingModel do
  @moduledoc """
  Dense embedding via Ollama nomic-embed-text (768-dim).
  Stateless HTTP client — no GenServer or supervision needed.
  """
  require Logger

  @default_model "nomic-embed-text"
  @timeout 30_000

  defp ollama_url do
    System.get_env("OLLAMA_URL") || Application.get_env(:elixir_nexus, :ollama_url, "http://localhost:11434")
  end

  defp ollama_model do
    System.get_env("OLLAMA_MODEL") || Application.get_env(:elixir_nexus, :ollama_model, @default_model)
  end

  @doc "Embed a single text. Returns {:ok, [float]} or {:error, reason}."
  def embed(text) when is_binary(text) do
    case embed_batch([text]) do
      {:ok, [embedding]} -> {:ok, embedding}
      error -> error
    end
  end

  @doc "Embed a batch of texts. Returns {:ok, [[float]]} or {:error, reason}."
  def embed_batch(texts) when is_list(texts) do
    url = "#{ollama_url()}/api/embed"
    body = Jason.encode!(%{model: ollama_model(), input: texts})

    case HTTPoison.post(url, body, [{"Content-Type", "application/json"}], recv_timeout: @timeout) do
      {:ok, %{status_code: 200, body: resp_body}} ->
        case Jason.decode(resp_body) do
          {:ok, %{"embeddings" => embeddings}} ->
            {:ok, embeddings}

          {:ok, other} ->
            Logger.warning("Unexpected Ollama response: #{inspect(other)}")
            {:error, :unexpected_response}

          {:error, reason} ->
            {:error, {:json_decode, reason}}
        end

      {:ok, %{status_code: code, body: resp_body}} ->
        Logger.warning("Ollama returned #{code}: #{resp_body}")
        {:error, {:http_error, code}}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.warning("Ollama connection failed: #{inspect(reason)}")
        {:error, {:connection_failed, reason}}
    end
  end

  @doc "Check if Ollama is reachable and the model is available."
  def available? do
    url = "#{ollama_url()}/api/tags"

    case HTTPoison.get(url, [], recv_timeout: 5_000) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"models" => models}} ->
            Enum.any?(models, fn m -> String.starts_with?(m["name"], ollama_model()) end)

          _ ->
            false
        end

      _ ->
        false
    end
  rescue
    _ -> false
  end
end
