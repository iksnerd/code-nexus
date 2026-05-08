defmodule ElixirNexus.HealthControllerTest do
  use ElixirNexus.ConnCase, async: false

  test "GET /health returns JSON with the expected keys", %{conn: conn} do
    conn = get(conn, "/health")

    # Status is 200 when all deps healthy, 503 otherwise — both are valid in CI
    # (Ollama may or may not be reachable). We just want to confirm the shape.
    assert conn.status in [200, 503]

    body = Jason.decode!(conn.resp_body)

    assert body["mcp"] == "healthy"
    assert body["qdrant"] in ["healthy", "degraded", "unreachable"]
    assert body["ollama"] in ["healthy", "degraded", "unreachable"]
    assert is_integer(body["indexed_projects"])
  end
end
