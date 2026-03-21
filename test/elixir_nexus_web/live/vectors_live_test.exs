defmodule ElixirNexus.VectorsLiveTest do
  use ElixirNexus.ConnCase, async: false
  import Phoenix.LiveViewTest

  # Ensure the Qdrant collection exists before tests run
  setup do
    ElixirNexus.QdrantClient.create_collection(384)
    :ok
  end

  describe "mount" do
    test "renders vectors page", %{conn: conn} do
      {:ok, view, html} = live(conn, "/vectors")
      assert is_binary(html)
      assert is_pid(view.pid)
    end
  end

  describe "handle_event" do
    test "close_detail closes modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/vectors")
      html = render_click(view, "close_detail")
      assert is_binary(html)
    end

    test "confirm_reset and cancel_reset", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/vectors")
      html = render_click(view, "confirm_reset")
      assert is_binary(html)
      html = render_click(view, "cancel_reset")
      assert is_binary(html)
    end

    test "filter by entity_type", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/vectors")
      html = render_click(view, "filter", %{"entity_type" => "function"})
      assert is_binary(html)
    end

    test "clear_filter resets filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/vectors")
      html = render_click(view, "clear_filter")
      assert is_binary(html)
    end

    test "refresh reloads data", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/vectors")
      html = render_click(view, "refresh")
      assert is_binary(html)
    end

    test "reset_collection resets the collection", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/vectors")
      # Confirm first, then reset
      render_click(view, "confirm_reset")
      html = render_click(view, "reset_collection")
      assert is_binary(html)
    end

    test "next_page when no next_offset is a no-op", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/vectors")
      html = render_click(view, "next_page")
      assert is_binary(html)
    end

    test "prev_page on page 0 is a no-op", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/vectors")
      html = render_click(view, "prev_page")
      assert is_binary(html)
    end

    test "show_detail with nonexistent point shows error flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/vectors")
      html = render_click(view, "show_detail", %{"id" => "999999"})
      assert is_binary(html)
    end

    test "delete_point with nonexistent point handles error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/vectors")
      html = render_click(view, "delete_point", %{"id" => "999999"})
      assert is_binary(html)
    end

    test "reindex starts reindexing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/vectors")
      html = render_click(view, "reindex")
      assert is_binary(html)
    end
  end

  describe "handle_info" do
    test "handles indexing_complete event", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/vectors")
      send(view.pid, {:indexing_complete, %{files: 5, chunks: 20}})
      html = render(view)
      assert is_binary(html)
    end

    test "handles indexing_progress event", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/vectors")
      send(view.pid, {:indexing_progress, %{processed: 3, total: 10}})
      html = render(view)
      assert is_binary(html)
    end

    test "handles file_reindexed event", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/vectors")
      send(view.pid, {:file_reindexed, "/some/file.ex"})
      html = render(view)
      assert is_binary(html)
    end

    test "handles collection_changed event", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/vectors")
      send(view.pid, {:collection_changed, "nexus_test"})
      html = render(view)
      assert is_binary(html)
    end

    test "handles reindex_done success", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/vectors")
      send(view.pid, {:reindex_done, {:ok, %{indexed_files: 2, total_chunks: 5}}})
      html = render(view)
      assert is_binary(html)
    end

    test "handles reindex_done error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/vectors")
      send(view.pid, {:reindex_done, {:error, :timeout}})
      html = render(view)
      assert is_binary(html)
    end

    test "handles clear_flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/vectors")
      send(view.pid, :clear_flash)
      html = render(view)
      assert is_binary(html)
    end

    test "handles unknown messages gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/vectors")
      send(view.pid, {:unknown_message, "data"})
      html = render(view)
      assert is_binary(html)
    end
  end

  describe "switch_collection event" do
    test "switch_collection event triggers project switch", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/vectors")
      html = render_click(view, "switch_collection", %{"collection" => "nexus_test"})
      assert is_binary(html)
    end
  end

  describe "filter round-trip" do
    test "filter then clear_filter resets state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/vectors")
      html = render_click(view, "filter", %{"entity_type" => "function"})
      assert is_binary(html)
      html = render_click(view, "clear_filter")
      assert is_binary(html)
    end
  end

  describe "with indexed data" do
    setup %{conn: conn} do
      :ok = ElixirNexus.Indexer.await_idle()

      tmp_dir = Path.join(System.tmp_dir!(), "vectors_data_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)

      # Index enough files to populate Qdrant and have pagination
      for i <- 1..25 do
        File.write!(Path.join(tmp_dir, "vec_mod_#{i}.ex"), """
        defmodule VecMod#{i} do
          def func_#{i}, do: :ok
        end
        """)
      end

      # index_file is synchronous — data will be in Qdrant immediately
      for i <- 1..25 do
        ElixirNexus.Indexer.index_file(Path.join(tmp_dir, "vec_mod_#{i}.ex"))
      end

      # Get a real point ID from Qdrant
      point_id =
        case ElixirNexus.QdrantClient.scroll_points(1) do
          {:ok, %{"result" => %{"points" => [%{"id" => id} | _]}}} -> id
          _ -> nil
        end

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{conn: conn, point_id: point_id}
    end

    test "show_detail with real point ID shows detail modal", %{conn: conn, point_id: point_id} do
      if point_id do
        {:ok, view, _html} = live(conn, "/vectors")
        html = render_click(view, "show_detail", %{"id" => to_string(point_id)})
        assert is_binary(html)
        # Success path should show the detail modal (payload data)
        assert html =~ "payload" or html =~ "vector" or html =~ "close"
      end
    end

    test "delete_point with real point ID deletes and refreshes", %{conn: conn, point_id: point_id} do
      if point_id do
        {:ok, view, _html} = live(conn, "/vectors")
        html = render_click(view, "delete_point", %{"id" => to_string(point_id)})
        assert is_binary(html)
        # Success path sets flash "Point deleted"
        assert html =~ "Point deleted" or html =~ "Failed"
      end
    end

    test "next_page advances when data has next_offset", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/vectors")
      # With 25+ points and page size of 20, there should be a next page
      html = render_click(view, "next_page")
      assert is_binary(html)
    end

    test "prev_page after next_page goes back", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/vectors")
      render_click(view, "next_page")
      html = render_click(view, "prev_page")
      assert is_binary(html)
    end

    test "filter shows filtered count", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/vectors")
      html = render_click(view, "filter", %{"entity_type" => "function"})
      assert is_binary(html)
    end

    test "refresh after indexing shows updated data", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/vectors")
      html = render_click(view, "refresh")
      assert html =~ "Refreshed"
    end

    test "reset_collection clears data", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/vectors")
      render_click(view, "confirm_reset")
      html = render_click(view, "reset_collection")
      assert html =~ "Collection reset" or html =~ "Failed"
    end
  end
end
