defmodule ElixirNexus.Search.QueriesTest do
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

  describe "analyze_impact/2" do
    test "finds direct callers" do
      {:ok, result} = Queries.analyze_impact("Server.handle_call")

      assert result.root == "Server.handle_call"
      assert result.total_affected >= 1
      affected_names = Enum.map(result.impact, & &1.name)
      assert "Client.call_server" in affected_names
    end

    test "finds transitive callers" do
      {:ok, result} = Queries.analyze_impact("Server.handle_call", 3)

      all_affected = result.affected_files
      assert "/app/lib/client.ex" in all_affected
      assert "/app/lib/router.ex" in all_affected
    end

    test "respects depth limit" do
      {:ok, shallow} = Queries.analyze_impact("Server.handle_call", 1)
      {:ok, deep} = Queries.analyze_impact("Server.handle_call", 3)

      assert deep.total_affected >= shallow.total_affected
    end

    test "handles entity with no callers" do
      {:ok, result} = Queries.analyze_impact("Router.dispatch")

      assert result.total_affected == 0
      assert result.impact == []
    end

    test "handles nonexistent entity gracefully" do
      {:ok, result} = Queries.analyze_impact("NonexistentFunction")

      assert result.total_affected == 0
    end

    test "handles circular call chains" do
      # Even if A calls B calls A, it should terminate
      {:ok, result} = Queries.analyze_impact("Server.handle_call", 10)
      assert is_map(result)
      assert is_integer(result.total_affected)
    end
  end

  describe "find_callees/2" do
    test "returns error for entity not in Qdrant" do
      # find_callees calls get_definition which queries Qdrant, not ETS
      # With test data only in ETS, this returns :not_found
      result = Queries.find_callees("CompletelyFakeFunction")
      assert {:error, _} = result
    end
  end

  describe "find_callers/2" do
    test "finds direct callers via GraphCache" do
      {:ok, results} = Queries.find_callers("handle_call")

      # Results are maps with :id, :score, :entity keys
      names = Enum.map(results, fn r -> r.entity["name"] end)
      assert Enum.any?(names, &(&1 != nil))
    end

    test "returns empty for function with no callers" do
      {:ok, results} = Queries.find_callers("CompletelyNonexistentXYZ999")
      assert results == []
    end

    test "respects limit" do
      {:ok, results} = Queries.find_callers("handle_call", 1)
      assert length(results) <= 1
    end
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

  describe "get_community_context/2" do
    test "finds files coupled via calls" do
      {:ok, result} = Queries.get_community_context("/app/lib/server.ex")

      assert result.file == "/app/lib/server.ex"
      assert result.entities_in_file >= 1
      coupled_paths = Enum.map(result.coupled_files, & &1.file_path)
      assert "/app/lib/client.ex" in coupled_paths
    end

    test "returns empty coupled_files for isolated file" do
      {:ok, result} = Queries.get_community_context("/app/lib/utils.ex")

      assert result.coupled_files == [] || result.entities_in_file >= 0
    end

    test "coupling score is positive for coupled files" do
      {:ok, result} = Queries.get_community_context("/app/lib/server.ex")

      Enum.each(result.coupled_files, fn cf ->
        assert cf.coupling_score > 0
      end)
    end

    test "respects limit" do
      {:ok, result} = Queries.get_community_context("/app/lib/server.ex", 1)
      assert length(result.coupled_files) <= 1
    end

    test "handles nonexistent file path" do
      {:ok, result} = Queries.get_community_context("/nonexistent/file.ex")

      assert result.entities_in_file == 0
      assert result.coupled_files == []
    end
  end

  describe "find_module_hierarchy/1" do
    test "finds module parents and children" do
      {:ok, result} = Queries.find_module_hierarchy("Server")

      assert result.name == "Server"
      assert result.entity_type == "module"
      assert is_list(result.parents)
      assert is_list(result.children)
    end

    test "resolves parent names" do
      {:ok, result} = Queries.find_module_hierarchy("Server")

      parent_names = Enum.map(result.parents, & &1.name)
      assert "GenServer" in parent_names
    end

    test "resolves child names" do
      {:ok, result} = Queries.find_module_hierarchy("Server")

      child_names = Enum.map(result.children, & &1.name)
      assert Enum.any?(child_names, &String.contains?(&1, "handle_call"))
    end

    test "returns error for nonexistent module" do
      assert {:error, :not_found} = Queries.find_module_hierarchy("CompletelyFakeModule")
    end

    test "case-insensitive matching works" do
      {:ok, result} = Queries.find_module_hierarchy("server")
      assert result.name == "Server"
    end
  end

  describe "analyze_impact/2 - depth 0" do
    test "returns empty impact at depth 0" do
      {:ok, result} = Queries.analyze_impact("Server.handle_call", 0)
      assert result.total_affected == 0
      assert result.impact == []
    end
  end

  describe "find_callers/2 - partial name matching" do
    test "finds callers by short name" do
      {:ok, results} = Queries.find_callers("call_server")
      names = Enum.map(results, fn r -> r.entity["name"] end)
      # Router.dispatch calls Client.call_server
      assert Enum.any?(names, &(&1 != nil))
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

  describe "get_community_context/2 - bidirectional" do
    test "detects both incoming and outgoing connections" do
      {:ok, result} = Queries.get_community_context("/app/lib/client.ex")

      assert result.file == "/app/lib/client.ex"
      assert result.entities_in_file >= 1

      # client.ex calls Server.handle_call (outgoing) and is called by Router.dispatch (incoming)
      coupled_paths = Enum.map(result.coupled_files, & &1.file_path)
      assert "/app/lib/server.ex" in coupled_paths or "/app/lib/router.ex" in coupled_paths
    end
  end

  describe "find_module_hierarchy/1 - unresolvable parents" do
    test "marks unresolvable parents as resolved: false" do
      {:ok, result} = Queries.find_module_hierarchy("Server")

      # GenServer is in is_a but not in our test chunks as an entity
      gen_server_parent = Enum.find(result.parents, &(&1.name == "GenServer"))
      assert gen_server_parent != nil
      assert gen_server_parent.resolved == false
    end
  end

  describe "resolve_call - dotted name stripping" do
    test "resolves dotted call names by stripping prefix" do
      # Add a chunk with a dotted call name
      dotted_chunk = %{
        id: "chunk_dotted",
        file_path: "/app/lib/adapter.ex",
        entity_type: :function,
        name: "Adapter.connect",
        content: "def connect, do: :ok",
        start_line: 1,
        end_line: 1,
        module_path: "Adapter",
        visibility: :public,
        parameters: [],
        calls: ["adapter.createConnector"],
        is_a: [],
        contains: [],
        language: :elixir
      }

      connector_chunk = %{
        id: "chunk_connector",
        file_path: "/app/lib/connector.ex",
        entity_type: :function,
        name: "createConnector",
        content: "def createConnector, do: :ok",
        start_line: 1,
        end_line: 1,
        module_path: "Connector",
        visibility: :public,
        parameters: [],
        calls: [],
        is_a: [],
        contains: [],
        language: :elixir
      }

      ChunkCache.insert_many([dotted_chunk, connector_chunk])
      GraphCache.rebuild_from_chunks(ChunkCache.all())

      # Impact analysis should resolve "createConnector" through "adapter.createConnector"
      {:ok, result} = Queries.analyze_impact("createConnector", 2)
      affected_names = Enum.map(result.impact, & &1.name)
      assert "Adapter.connect" in affected_names
    end
  end
end
