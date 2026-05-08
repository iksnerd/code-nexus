defmodule ElixirNexus.HealthController do
  @moduledoc """
  Liveness/readiness endpoint for Docker healthchecks and operators.

  Returns `{mcp, qdrant, ollama, indexed_projects}` as JSON. Each dependency
  is `"healthy"`, `"degraded"`, or `"unreachable"`. The HTTP status is `200`
  if every dependency is healthy, `503` otherwise — so docker-compose
  healthchecks can rely on a non-200 response when Ollama or Qdrant is down.
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

    status_code = if qdrant == "healthy" and ollama == "healthy", do: 200, else: 503

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status_code, Jason.encode!(body))
  end

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
    if ElixirNexus.EmbeddingModel.available?(), do: "healthy", else: "unreachable"
  rescue
    _ -> "unreachable"
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
