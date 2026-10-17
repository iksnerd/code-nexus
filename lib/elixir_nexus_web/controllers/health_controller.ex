defmodule ElixirNexus.HealthController do
  @moduledoc """
  Liveness/readiness endpoint for Docker healthchecks and operators.

  Returns `{mcp, qdrant, ollama, indexed_projects}` as JSON. Qdrant is
  `"healthy"`, `"degraded"`, or `"unreachable"`. Ollama is optional (embeddings
  fall back to TF-IDF), so it is `"healthy"` or `"degraded"`. The HTTP status
  is `200` when Qdrant is healthy and `503` otherwise; a degraded Ollama is
  reported in the body but does not fail the check.
  """

  use Phoenix.Controller

  def index(conn, _params) do
    qdrant = qdrant_status()
    ollama = ollama_status()
    projects = indexed_projects_count()

    body = %{
      mcp: "healthy",
      qdrant: qdrant,
      ollama: ollama,
      indexed_projects: projects
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status_code(qdrant, ollama), Jason.encode!(body))
  end

  @doc false
  def status_code("healthy", _ollama), do: 200
  def status_code(_qdrant, _ollama), do: 503

  defp qdrant_status do
    case ElixirNexus.QdrantClient.health_check() do
      {:ok, _} -> "healthy"
      {:error, _} -> "unreachable"
    end
  rescue
    _ -> "unreachable"
  catch
    :exit, _ -> "unreachable"
  end

  defp ollama_status do
    if ElixirNexus.EmbeddingModel.available?(), do: "healthy", else: "degraded"
  rescue
    _ -> "degraded"
  end

  defp indexed_projects_count do
    case ElixirNexus.QdrantClient.list_collections() do
      {:ok, names} -> Enum.count(names, &String.starts_with?(&1, "nexus_"))
      _ -> 0
    end
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end
end
