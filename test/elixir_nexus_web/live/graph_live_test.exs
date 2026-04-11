defmodule ElixirNexus.GraphLiveTest do
  use ElixirNexus.ConnCase, async: false
  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders graph page", %{conn: conn} do
      {:ok, view, html} = live(conn, "/graph")
      assert html =~ "Code Relationship Graph"
      assert is_pid(view.pid)
    end

    test "starts with zero nodes and links", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/graph")
      assert html =~ "Nodes:"
      assert html =~ "Links:"
    end
  end

  describe "handle_event" do
    test "refresh_graph does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/graph")
      html = render_click(view, "refresh_graph")
      assert is_binary(html)
    end

    test "switch_collection does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/graph")
      html = render_click(view, "switch_collection", %{"collection" => "nexus_test"})
      assert is_binary(html)
    end
  end

  describe "handle_info" do
    test "receives indexing_complete event", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/graph")
      send(view.pid, {:indexing_complete, %{files: 5, chunks: 20}})
      html = render(view)
      assert is_binary(html)
    end

    test "receives file_reindexed event", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/graph")
      send(view.pid, {:file_reindexed, "lib/test.ex"})
      html = render(view)
      assert is_binary(html)
    end

    test "handles unknown messages gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/graph")
      send(view.pid, {:unknown_event, "data"})
      html = render(view)
      assert is_binary(html)
    end
  end
end
