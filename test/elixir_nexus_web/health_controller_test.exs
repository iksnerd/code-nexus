defmodule ElixirNexus.HealthControllerTest do
  use ElixirNexus.ConnCase, async: false

  test "GET /health returns JSON with the expected keys", %{conn: conn} do
    conn = get(conn, "/health")

    # Status follows Qdrant alone, so 200 or 503 are both valid in CI. We just
    # want to confirm the shape.
    assert conn.status in [200, 503]

    body = Jason.decode!(conn.resp_body)

    assert body["mcp"] == "healthy"
    assert body["qdrant"] in ["healthy", "degraded", "unreachable"]
    assert body["ollama"] in ["healthy", "degraded"]
    assert is_integer(body["indexed_projects"])
  end

  describe "status_code/2" do
    test "an unreachable Ollama degrades the report but does not fail it" do
      # Embeddings fall back to TF-IDF, so the server still works.
      assert ElixirNexus.HealthController.status_code("healthy", "degraded") == 200
    end

    test "everything healthy is 200" do
      assert ElixirNexus.HealthController.status_code("healthy", "healthy") == 200
    end

    test "Qdrant not healthy is 503 whatever Ollama says" do
      assert ElixirNexus.HealthController.status_code("unreachable", "healthy") == 503
      assert ElixirNexus.HealthController.status_code("degraded", "healthy") == 503
    end
  end
end
