defmodule ElixirNexus.StaticAssetsTest do
  use ElixirNexus.ConnCase, async: true

  @vendor_js [
    "/js/phoenix.min.js",
    "/js/phoenix_live_view.min.js",
    "/js/app.js"
  ]

  describe "vendor JS files" do
    for path <- @vendor_js do
      test "#{path} is served with 200", %{conn: conn} do
        conn = get(conn, unquote(path))
        assert response(conn, 200)
        assert response_content_type(conn, :javascript) =~ "javascript"
      end
    end
  end

  describe "static assets" do
    test "/images/favicon.svg is served", %{conn: conn} do
      conn = get(conn, "/images/favicon.svg")
      assert response(conn, 200)
    end

    test "/images/logo.svg is served", %{conn: conn} do
      conn = get(conn, "/images/logo.svg")
      assert response(conn, 200)
    end
  end
end
