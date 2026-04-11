defmodule ElixirNexus.Search.CalleeFinderTest do
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

  describe "find_callees/2" do
    test "returns error for entity not in Qdrant" do
      # find_callees calls get_definition which queries Qdrant, not ETS
      # With test data only in ETS, this returns :not_found
      result = Queries.find_callees("CompletelyFakeFunction")
      assert {:error, _} = result
    end
  end

  describe "find_callees/2 - fuzzy name matching via multi-strategy" do
    setup do
      chunks = [
        %{
          id: "fuzzy_target",
          file_path: "/app/lib/service.ex",
          entity_type: :function,
          name: "MyService.run",
          content: "def run, do: :ok",
          start_line: 1,
          end_line: 5,
          module_path: "MyService",
          visibility: :public,
          parameters: [],
          calls: ["Logger.info", "Helper.format"],
          is_a: [],
          contains: [],
          language: :elixir
        }
      ]

      ChunkCache.insert_many(chunks)
      GraphCache.rebuild_from_chunks(ChunkCache.all())
      :ok
    end

    test "finds entity by lowercase name (case-insensitive)" do
      # "myservice.run" should match "MyService.run" via multi-strategy
      {:ok, results} = Queries.find_callees("myservice.run")
      assert is_list(results)
      assert results != []
    end

    test "finds entity by short name (substring match)" do
      # "run" alone should match "MyService.run" via substring strategy
      {:ok, results} = Queries.find_callees("run")
      assert is_list(results)
      assert results != []
    end

    test "returns :not_found for completely unknown entity" do
      assert {:error, :not_found} = Queries.find_callees("TotallyNonexistentXYZ999")
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
