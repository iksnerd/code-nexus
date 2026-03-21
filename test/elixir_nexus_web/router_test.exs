defmodule ElixirNexus.RouterTest do
  use ElixirNexus.ConnCase, async: false

  test "GET / returns 200", %{conn: conn} do
    conn = get(conn, "/")
    assert html_response(conn, 200)
  end

  test "GET /vectors returns 200", %{conn: conn} do
    conn = get(conn, "/vectors")
    assert html_response(conn, 200)
  end
end
