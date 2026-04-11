defmodule ElixirNexus.Search.GraphStatsTest do
  use ExUnit.Case, async: false

  alias ElixirNexus.Search.Queries
  alias ElixirNexus.ChunkCache
  alias ElixirNexus.GraphCache

  @test_chunks [
    %{
      id: "chunk_1",
      file_path: "/app/lib/server.ex",
      entity_type: :module,
      name: "Server",
      content: "defmodule Server do\nend",
      start_line: 1,
      end_line: 10,
      module_path: "Server",
      visibility: :public,
      parameters: [],
      calls: ["GenServer.start_link", "handle_call"],
      is_a: ["GenServer"],
      contains: ["Server.handle_call", "Server.init"],
      language: :elixir
    },
    %{
      id: "chunk_2",
      file_path: "/app/lib/server.ex",
      entity_type: :function,
      name: "Server.handle_call",
      content: "def handle_call(:ping, _from, state) do\n  {:reply, :pong, state}\nend",
      start_line: 5,
      end_line: 7,
      module_path: "Server",
      visibility: :public,
      parameters: ["msg", "_from", "state"],
      calls: ["Logger.info"],
      is_a: [],
      contains: [],
      language: :elixir
    },
    %{
      id: "chunk_3",
      file_path: "/app/lib/client.ex",
      entity_type: :function,
      name: "Client.call_server",
      content: "def call_server(msg) do\n  Server.handle_call(msg)\nend",
      start_line: 1,
      end_line: 3,
      module_path: "Client",
      visibility: :public,
      parameters: ["msg"],
      calls: ["Server.handle_call"],
      is_a: [],
      contains: [],
      language: :elixir
    },
    %{
      id: "chunk_4",
      file_path: "/app/lib/router.ex",
      entity_type: :function,
      name: "Router.dispatch",
      content: "def dispatch(req) do\n  Client.call_server(req)\nend",
      start_line: 1,
      end_line: 3,
      module_path: "Router",
      visibility: :public,
      parameters: ["req"],
      calls: ["Client.call_server"],
      is_a: [],
      contains: [],
      language: :elixir
    },
    %{
      id: "chunk_5",
      file_path: "/app/lib/utils.ex",
      entity_type: :function,
      name: "Utils.format",
      content: "def format(data), do: data",
      start_line: 1,
      end_line: 1,
      module_path: "Utils",
      visibility: :public,
      parameters: ["data"],
      calls: [],
      is_a: [],
      contains: [],
      language: :elixir
    }
  ]

  setup do
    # Populate ETS caches with test data
    ChunkCache.clear()
    GraphCache.clear()

    ChunkCache.insert_many(@test_chunks)
    GraphCache.rebuild_from_chunks(@test_chunks)

    on_exit(fn ->
      ChunkCache.clear()
      GraphCache.clear()
    end)

    :ok
  end

  describe "get_graph_stats/0" do
    test "returns stats with expected keys" do
      {:ok, stats} = Queries.get_graph_stats()

      assert is_integer(stats.total_nodes)
      assert is_integer(stats.total_chunks)
      assert is_list(stats.entity_types)
      assert is_map(stats.edge_counts)
      assert is_list(stats.top_connected)
      assert is_list(stats.languages)
    end

    test "entity_types breakdown is correct" do
      {:ok, stats} = Queries.get_graph_stats()

      type_names = Enum.map(stats.entity_types, & &1.type)
      assert Enum.any?(type_names, &(&1 in ["function", "module"]))
    end

    test "edge counts are non-negative" do
      {:ok, stats} = Queries.get_graph_stats()

      assert stats.edge_counts.calls >= 0
      assert stats.edge_counts.imports >= 0
      assert stats.edge_counts.contains >= 0
    end

    test "top_connected returns up to 10 entries" do
      {:ok, stats} = Queries.get_graph_stats()
      assert length(stats.top_connected) <= 10
    end

    test "languages breakdown includes elixir" do
      {:ok, stats} = Queries.get_graph_stats()

      langs = Enum.map(stats.languages, & &1.language)
      assert "elixir" in langs
    end
  end

  describe "get_graph_stats/0 - empty caches" do
    test "returns zeros after clearing caches" do
      ChunkCache.clear()
      GraphCache.clear()

      {:ok, stats} = Queries.get_graph_stats()
      assert stats.total_nodes == 0
      assert stats.total_chunks == 0
    end
  end

  describe "get_graph_stats critical_files" do
    test "returns critical_files field" do
      {:ok, stats} = Queries.get_graph_stats()

      assert Map.has_key?(stats, :critical_files)
      assert is_list(stats.critical_files)
    end
  end

  describe "get_graph_stats/0 - critical_files with connected graph" do
    test "critical_files returns entries when graph has connected nodes" do
      # Build a denser graph: A → B → C → D → E, all passing through B and C
      chain = [
        %{
          id: "c_a",
          file_path: "/app/lib/a.ex",
          entity_type: :function,
          name: "A.run",
          content: "",
          start_line: 1,
          end_line: 1,
          module_path: "A",
          visibility: :public,
          parameters: [],
          calls: ["B.run"],
          is_a: [],
          contains: [],
          language: :elixir
        },
        %{
          id: "c_b",
          file_path: "/app/lib/b.ex",
          entity_type: :function,
          name: "B.run",
          content: "",
          start_line: 1,
          end_line: 1,
          module_path: "B",
          visibility: :public,
          parameters: [],
          calls: ["C.run"],
          is_a: [],
          contains: [],
          language: :elixir
        },
        %{
          id: "c_c",
          file_path: "/app/lib/c.ex",
          entity_type: :function,
          name: "C.run",
          content: "",
          start_line: 1,
          end_line: 1,
          module_path: "C",
          visibility: :public,
          parameters: [],
          calls: ["D.run"],
          is_a: [],
          contains: [],
          language: :elixir
        },
        %{
          id: "c_d",
          file_path: "/app/lib/d.ex",
          entity_type: :function,
          name: "D.run",
          content: "",
          start_line: 1,
          end_line: 1,
          module_path: "D",
          visibility: :public,
          parameters: [],
          calls: ["E.run"],
          is_a: [],
          contains: [],
          language: :elixir
        },
        %{
          id: "c_e",
          file_path: "/app/lib/e.ex",
          entity_type: :function,
          name: "E.run",
          content: "",
          start_line: 1,
          end_line: 1,
          module_path: "E",
          visibility: :public,
          parameters: [],
          calls: [],
          is_a: [],
          contains: [],
          language: :elixir
        }
      ]

      ChunkCache.clear()
      GraphCache.clear()
      ChunkCache.insert_many(chain)
      GraphCache.rebuild_from_chunks(chain)

      {:ok, stats} = Queries.get_graph_stats()

      assert is_list(stats.critical_files)
      # B, C, D sit on the only path A→E so they must have centrality > 0
      assert length(stats.critical_files) > 0,
             "Expected critical_files to be non-empty for a linear chain graph"

      Enum.each(stats.critical_files, fn cf ->
        assert cf.file_path != nil, "critical_files entry has nil file_path"
        assert is_number(cf.centrality_score)
      end)
    end
  end

  describe "get_graph_stats/0 - framework noise filtering" do
    test "excludes known framework utility names from top_connected" do
      noise_chunks =
        ~w(cn clsx Comp Slot twMerge)
        |> Enum.with_index()
        |> Enum.map(fn {name, i} ->
          callers =
            1..50
            |> Enum.map(fn j ->
              %{
                id: "caller_#{name}_#{j}",
                file_path: "/app/components/c#{j}.tsx",
                entity_type: :function,
                name: "Component#{j}.render",
                content: "",
                start_line: 1,
                end_line: 1,
                module_path: "Component#{j}",
                visibility: :public,
                parameters: [],
                calls: [name],
                is_a: [],
                contains: [],
                language: :typescript
              }
            end)

          noise_entity = %{
            id: "noise_#{i}",
            file_path: "/app/lib/utils.ts",
            entity_type: :function,
            name: name,
            content: "",
            start_line: i,
            end_line: i,
            module_path: name,
            visibility: :public,
            parameters: [],
            calls: [],
            is_a: [],
            contains: [],
            language: :typescript
          }

          [noise_entity | callers]
        end)
        |> List.flatten()

      ChunkCache.clear()
      GraphCache.clear()
      ChunkCache.insert_many(noise_chunks)
      GraphCache.rebuild_from_chunks(noise_chunks)

      {:ok, stats} = Queries.get_graph_stats()
      top_names = Enum.map(stats.top_connected, & &1.name)

      refute "cn" in top_names, "cn should be filtered from top_connected"
      refute "clsx" in top_names, "clsx should be filtered from top_connected"
      refute "Comp" in top_names, "Comp should be filtered from top_connected"
    end

    test "legitimate high-connectivity app nodes are NOT filtered" do
      # A real app function called by many components should still appear in top_connected
      callers =
        1..20
        |> Enum.map(fn j ->
          %{
            id: "caller_fetch_#{j}",
            file_path: "/app/components/c#{j}.tsx",
            entity_type: :function,
            name: "Component#{j}.render",
            content: "",
            start_line: 1,
            end_line: 1,
            module_path: "Component#{j}",
            visibility: :public,
            parameters: [],
            calls: ["fetchUsers"],
            is_a: [],
            contains: [],
            language: :typescript
          }
        end)

      fetch_entity = %{
        id: "fetch_users",
        file_path: "/app/lib/api.ts",
        entity_type: :function,
        name: "fetchUsers",
        content: "",
        start_line: 1,
        end_line: 1,
        module_path: "fetchUsers",
        visibility: :public,
        parameters: [],
        calls: [],
        is_a: [],
        contains: [],
        language: :typescript
      }

      ChunkCache.clear()
      GraphCache.clear()
      ChunkCache.insert_many([fetch_entity | callers])
      GraphCache.rebuild_from_chunks([fetch_entity | callers])

      {:ok, stats} = Queries.get_graph_stats()
      top_names = Enum.map(stats.top_connected, & &1.name)

      assert "fetchUsers" in top_names,
             "Legitimate high-connectivity function should appear in top_connected"
    end
  end
end
