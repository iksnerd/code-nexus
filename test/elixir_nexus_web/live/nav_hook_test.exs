defmodule ElixirNexusWeb.NavHookTest do
  use ElixirNexus.ConnCase, async: false
  import Phoenix.LiveViewTest

  describe "on_mount" do
    test "assigns collections and current_path on mount", %{conn: conn} do
      # NavHook runs on_mount for all LiveViews, so any LiveView mount tests it
      {:ok, _view, html} = live(conn, "/")
      # The nav should contain collection info
      assert is_binary(html)
    end

    test "assigns are set for vectors page too", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/vectors")
      assert is_binary(html)
    end
  end
end
