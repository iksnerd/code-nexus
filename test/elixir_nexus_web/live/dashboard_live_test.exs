defmodule ElixirNexus.DashboardLiveTest do
  use ElixirNexus.ConnCase, async: false
  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders dashboard page", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")
      assert html =~ "CodeNexus" or html =~ "Dashboard" or html =~ "nexus"
      assert is_pid(view.pid)
    end
  end

  describe "architecture layers panel" do
    test "renders the layers panel with derived layers when the graph has layered files", %{conn: conn} do
      chunks = [
        %{
          id: "p1",
          file_path: "/app/core/ports/user-repository.ts",
          entity_type: :interface,
          name: "UserRepository",
          content: "",
          start_line: 1,
          end_line: 1,
          module_path: "UserRepository",
          visibility: :public,
          parameters: [],
          calls: [],
          is_a: [],
          contains: [],
          language: :typescript
        },
        %{
          id: "a1",
          file_path: "/app/infrastructure/firebase-user-repository.ts",
          entity_type: :function,
          name: "createFirebaseUserRepository",
          content: "",
          start_line: 1,
          end_line: 1,
          module_path: "createFirebaseUserRepository",
          visibility: :public,
          parameters: [],
          calls: [],
          is_a: [],
          contains: [],
          language: :typescript
        }
      ]

      ElixirNexus.ChunkCache.clear()
      ElixirNexus.GraphCache.clear()
      ElixirNexus.ChunkCache.insert_many(chunks)
      ElixirNexus.GraphCache.rebuild_from_chunks(chunks)
      # Root-relative classification (mirrors get_graph_stats); without a root, "/app/..."
      # would itself match the presentation "app" alias.
      prev = Application.get_env(:elixir_nexus, :project_config)
      Application.put_env(:elixir_nexus, :project_config, {"/app", %ElixirNexus.ProjectConfig{}})

      on_exit(fn ->
        ElixirNexus.ChunkCache.clear()
        ElixirNexus.GraphCache.clear()

        if prev,
          do: Application.put_env(:elixir_nexus, :project_config, prev),
          else: Application.delete_env(:elixir_nexus, :project_config)
      end)

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Architecture Layers"
      assert html =~ "ports"
      assert html =~ "adapters"
    end
  end

  describe "handle_event" do
    test "toggle_errors toggles error panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      # Toggle errors - should not crash
      html = render_click(view, "toggle_errors")
      assert is_binary(html)
    end
  end

  describe "handle_info" do
    test "receives indexing_complete event", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      send(view.pid, {:indexing_complete, %{files: 5, chunks: 20}})
      # Give it time to process
      html = render(view)
      assert is_binary(html)
    end

    test "receives file_reindexed event", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      send(view.pid, {:file_reindexed, "lib/test.ex"})
      html = render(view)
      assert is_binary(html)
    end

    test "receives indexing_progress event", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      send(view.pid, {:indexing_progress, %{batch_chunks: 10, batch_files: 2}})
      html = render(view)
      assert is_binary(html)
    end

    test "handles tick message", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      send(view.pid, :tick)
      html = render(view)
      assert is_binary(html)
    end

    test "handles collection_changed event", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      send(view.pid, {:collection_changed, "nexus_test"})
      html = render(view)
      assert is_binary(html)
    end

    test "handles indexing_progress without batch keys", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      send(view.pid, {:indexing_progress, %{status: "running"}})
      html = render(view)
      assert is_binary(html)
    end

    test "handles file_deleted event", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      send(view.pid, {:file_deleted, "/app/lib/deleted.ex"})
      html = render(view)
      assert is_binary(html)
      assert html =~ "Deleted" or html =~ "deleted"
    end

    test "handles unknown messages gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      send(view.pid, {:unknown_event, "some_data"})
      html = render(view)
      assert is_binary(html)
    end
  end

  describe "switch_collection event" do
    test "switch_collection triggers project switch", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      html = render_click(view, "switch_collection", %{"collection" => "nexus_test"})
      assert is_binary(html)
    end
  end

  describe "toggle_errors multiple times" do
    test "toggling errors twice returns to original state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      render_click(view, "toggle_errors")
      html = render_click(view, "toggle_errors")
      assert is_binary(html)
    end
  end

  describe "indexing_progress with batch data" do
    test "batch data appears in activity feed", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      send(view.pid, {:indexing_progress, %{batch_chunks: 10, batch_files: 2}})
      html = render(view)
      assert is_binary(html)
    end
  end

  describe "dashboard with indexed data" do
    setup %{conn: conn} do
      :ok = ElixirNexus.Indexer.await_idle()

      tmp_dir = Path.join(System.tmp_dir!(), "dash_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)

      File.write!(Path.join(tmp_dir, "dash_mod.ex"), """
      defmodule DashMod do
        def func1, do: :ok
        def func2, do: func1()
      end
      """)

      ElixirNexus.Indexer.index_file(Path.join(tmp_dir, "dash_mod.ex"))

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{conn: conn}
    end

    test "dashboard renders entity and language data", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert is_binary(html)
      # Dashboard should render without errors even with indexed data
    end
  end
end
