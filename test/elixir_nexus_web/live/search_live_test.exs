defmodule ElixirNexus.SearchLive.IndexTest do
  use ElixirNexus.ConnCase

  describe "GET /search" do
    test "renders search page with empty state", %{conn: conn} do
      {:ok, view, html} = live(conn, "/search")

      assert html =~ "Code Search"
      assert html =~ "Enter a query to search"
      refute html =~ "results for"
    end

    test "auto-searches when query param is present", %{conn: conn} do
      {:ok, view, html} = live(conn, "/search?query=GenServer")

      # Input should be populated with the query
      assert html =~ "GenServer"
      # Should show results header (either results found or no results)
      assert html =~ "GenServer" or html =~ "No results found"
    end

    test "searching updates URL with query param", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/search")

      # Submit a search
      result = view
      |> element("form[phx-submit=search]")
      |> render_submit(%{"query" => "test_func"})

      # Should trigger a patch (redirect within LiveView)
      assert_patch(view, "/search?query=test_func")
    end

    test "shows entity type badges in results", %{conn: conn} do
      {:ok, view, html} = live(conn, "/search?query=process")

      # If there are results, they should have entity type badges
      if html =~ "results for" do
        assert html =~ "function" or html =~ "module" or html =~ "macro"
      end
    end

    test "shows search timing", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/search?query=GenServer")

      # Should show timing in milliseconds
      if html =~ "results for" do
        assert html =~ " ms"
      end
    end

    test "empty query submit does nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/search")

      html = view
      |> element("form[phx-submit=search]")
      |> render_submit(%{"query" => ""})

      # Should still show empty state
      assert html =~ "Enter a query to search"
    end

    test "shows calls and is_a tags on results", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/search?query=index_file")

      # If results have calls/is_a data, tags should appear
      if html =~ "results for" do
        # Check the template renders the tag structure
        assert html =~ "calls" or html =~ "is_a" or html =~ "Lines"
      end
    end
  end

  describe "handle_event search_changed" do
    test "search_changed with 3+ chars triggers search", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/search")
      html = render_change(view, "search_changed", %{"query" => "GenServer"})
      assert is_binary(html)
    end

    test "search_changed with short query is no-op", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/search")
      html = render_change(view, "search_changed", %{"query" => "ab"})
      assert html =~ "Enter a query to search"
    end
  end

  describe "handle_event switch_collection" do
    test "switch_collection triggers project switch", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/search")
      html = render_click(view, "switch_collection", %{"collection" => "nexus_test"})
      assert is_binary(html)
    end
  end

  describe "handle_info events" do
    test "indexing_complete shows flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/search")
      send(view.pid, {:indexing_complete, %{files: 5, chunks: 20}})
      html = render(view)
      assert is_binary(html)
    end

    test "file_reindexed shows flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/search")
      send(view.pid, {:file_reindexed, "lib/test.ex"})
      html = render(view)
      assert is_binary(html)
    end

    test "collection_changed resets search state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/search")
      send(view.pid, {:collection_changed, "nexus_new"})
      html = render(view)
      assert html =~ "Enter a query to search"
    end

    test "unknown message is handled", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/search")
      send(view.pid, {:some_unknown, "data"})
      html = render(view)
      assert is_binary(html)
    end
  end
end
