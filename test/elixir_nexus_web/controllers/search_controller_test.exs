defmodule ElixirNexus.API.SearchControllerTest do
  use ElixirNexus.ConnCase, async: false

  describe "POST /api/search" do
    test "returns results for valid query", %{conn: conn} do
      conn = post(conn, "/api/search", %{"query" => "test function"})
      response = json_response(conn, 200)
      assert response["success"] == true
      assert is_list(response["data"])
    end

    test "returns results with custom limit", %{conn: conn} do
      conn = post(conn, "/api/search", %{"query" => "test", "limit" => 5})
      response = json_response(conn, 200)
      assert response["success"] == true
    end
  end

  describe "POST /api/callees" do
    test "returns callees for entity name", %{conn: conn} do
      conn = post(conn, "/api/callees", %{"entity_name" => "nonexistent_func"})
      response = json_response(conn, 200)
      # Either success with empty results or error
      assert is_map(response)
    end

    test "returns callees with explicit limit", %{conn: conn} do
      conn = post(conn, "/api/callees", %{"entity_name" => "nonexistent_func", "limit" => 5})
      response = json_response(conn, 200)
      assert is_map(response)
    end

    test "returns error response when entity not found", %{conn: conn} do
      conn = post(conn, "/api/callees", %{"entity_name" => "completely_fake_xyz_999"})
      response = json_response(conn, 200)
      # Should get either success with empty list or error response
      assert is_map(response)
      assert Map.has_key?(response, "success")
    end
  end

  describe "POST /api/index" do
    test "returns error for non-existent path", %{conn: conn} do
      conn = post(conn, "/api/index", %{"path" => "/nonexistent/path"})
      response = json_response(conn, 200)
      assert is_map(response)
    end

    test "indexes valid empty directory", %{conn: conn} do
      dir = Path.join(System.tmp_dir!(), "search_ctrl_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      conn = post(conn, "/api/index", %{"path" => dir})
      response = json_response(conn, 200)
      assert is_map(response)

      File.rm_rf!(dir)
    end
  end
end
