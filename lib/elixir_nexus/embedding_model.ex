defmodule ElixirNexus.EmbeddingModel do
  @moduledoc """
  Dense embedding via Ollama (default: embeddinggemma:300m, 768-dim).
  Stateless HTTP client — no GenServer or supervision needed.
  """
  require Logger

  @default_model "embeddinggemma:300m"
  @default_timeout 60_000
  @default_retry_attempts 3
  @default_retry_backoff_ms 1_000

  defp ollama_url do
    System.get_env("OLLAMA_URL") || Application.get_env(:elixir_nexus, :ollama_url, "http://localhost:11434")
  end

  defp ollama_model do
    System.get_env("OLLAMA_MODEL") || Application.get_env(:elixir_nexus, :ollama_model, @default_model)
  end

  defp ollama_timeout, do: Application.get_env(:elixir_nexus, :ollama_timeout, @default_timeout)
  defp retry_attempts, do: Application.get_env(:elixir_nexus, :ollama_retry_attempts, @default_retry_attempts)
  defp retry_backoff_ms, do: Application.get_env(:elixir_nexus, :ollama_retry_backoff_ms, @default_retry_backoff_ms)

  @doc "Embed a single text. Returns {:ok, [float]} or {:error, reason}."
  def embed(text) when is_binary(text) do
    case embed_batch([text]) do
      {:ok, [embedding]} -> {:ok, embedding}
      error -> error
    end
  end

  @doc """
  Embed a batch of texts. Returns {:ok, [[float]]} or {:error, reason}.
  Retries on transient errors (timeout, connection refused) with linear backoff —
  covers Ollama cold-start when the model is loading. Retry count and timeout
  are configurable via Application env (`:ollama_retry_attempts`, `:ollama_timeout`).
  """
  def embed_batch(texts) when is_list(texts) do
    if Application.get_env(:elixir_nexus, :env) == :test do
      # Test environment: skip the real Ollama call entirely. Callers that need
      # actual dense vectors should set up their own stub. Production-like
      # search paths fall through to the TF-IDF embedder, which is what the
      # vast majority of tests assume already.
      {:error, :test_mode}
    else
      do_embed_batch(texts, 1)
    end
  end

  defp do_embed_batch(texts, attempt) do
    url = "#{ollama_url()}/api/embed"
    body = Jason.encode!(%{model: ollama_model(), input: texts})

    case HTTPoison.post(url, body, [{"Content-Type", "application/json"}], recv_timeout: ollama_timeout()) do
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

      {:error, %HTTPoison.Error{reason: reason}}
      when reason in [:timeout, :connect_timeout, :econnrefused] ->
        if attempt < retry_attempts() do
          backoff = retry_backoff_ms() * attempt
          Logger.info("Ollama #{reason} on attempt #{attempt}/#{retry_attempts()}, retrying in #{backoff}ms")
          Process.sleep(backoff)
          do_embed_batch(texts, attempt + 1)
        else
          Logger.warning("Ollama connection failed: #{inspect(reason)}")
          {:error, {:connection_failed, reason}}
        end

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.warning("Ollama connection failed: #{inspect(reason)}")
        {:error, {:connection_failed, reason}}
    end
  end

  @doc """
  Issue a tiny embed request to force Ollama to load the model into memory.
  Called at supervisor start so the first real indexing batch doesn't block on cold load.
  """
  def warm_up do
    Task.start(fn ->
      case embed("warmup") do
        {:ok, _} ->
          Logger.info("Ollama warm-up succeeded for model #{ollama_model()}")

        {:error, reason} ->
          Logger.warning("Ollama warm-up failed: #{inspect(reason)} (will retry on first real request)")
      end
    end)
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
