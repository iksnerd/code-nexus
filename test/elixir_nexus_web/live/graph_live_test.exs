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

  describe "graph data" do
    setup do
      prev = Application.get_env(:elixir_nexus, :project_config)

      on_exit(fn ->
        ElixirNexus.ChunkCache.clear()
        ElixirNexus.GraphCache.clear()

        if prev,
          do: Application.put_env(:elixir_nexus, :project_config, prev),
          else: Application.delete_env(:elixir_nexus, :project_config)
      end)

      :ok
    end

    defp chunk(attrs) do
      attrs = Map.new(attrs)

      Map.merge(
        %{
          id: "#{attrs[:file_path]}:#{attrs[:name]}",
          entity_type: :function,
          content: "",
          start_line: 1,
          end_line: 1,
          module_path: nil,
          visibility: :public,
          parameters: [],
          calls: [],
          is_a: [],
          contains: []
        },
        attrs
      )
    end

    defp graph_nodes(conn, chunks, root) do
      ElixirNexus.ChunkCache.clear()
      ElixirNexus.GraphCache.clear()
      ElixirNexus.ChunkCache.insert_many(chunks)
      ElixirNexus.GraphCache.rebuild_from_chunks(chunks)
      Application.put_env(:elixir_nexus, :project_config, {root, %ElixirNexus.ProjectConfig{}})

      {:ok, view, _html} = live(conn, "/graph")
      render_click(view, "refresh_graph")
      assert_push_event(view, "graph_data", %{nodes: nodes})
      nodes
    end

    test "same-named folders in different parts of the project are different packages", %{conn: conn} do
      # gpt-alpha: web/app/src/components and glassbox/packages/ui/src/components
      # both became "src/components" and were merged into one box.
      nodes =
        graph_nodes(
          conn,
          [
            chunk(name: "AppButton", language: :tsx, file_path: "/w/web/app/src/components/button.tsx"),
            chunk(name: "GlassCard", language: :tsx, file_path: "/w/glassbox/packages/ui/src/components/card.tsx")
          ],
          "/w"
        )

      groups = Map.new(nodes, &{&1.name, &1.group})
      assert groups["AppButton"] != groups["GlassCard"]
    end

    test "builtin calls don't inflate a node's size", %{conn: conn} do
      # gpt-alpha rendered `len` as a giant bubble from Python's builtin len().
      callers =
        for i <- 1..10 do
          chunk(name: "step_#{i}", language: :python, file_path: "/w/train_#{i}.py", calls: ["len", "train_model"])
        end

      nodes =
        graph_nodes(
          conn,
          callers ++
            [
              chunk(name: "len", language: :python, file_path: "/w/utils/shape.py"),
              chunk(name: "train_model", language: :python, file_path: "/w/train.py")
            ],
          "/w"
        )

      vals = Map.new(nodes, &{&1.name, &1.val})
      assert vals["train_model"] > vals["len"]
    end
  end
end
