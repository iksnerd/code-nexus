defmodule ElixirNexus.Search.ImpactAnalysisTest do
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

  describe "analyze_impact/2 - depth 0" do
    test "returns empty impact at depth 0" do
      {:ok, result} = Queries.analyze_impact("Server.handle_call", 0)
      assert result.total_affected == 0
      assert result.impact == []
    end
  end

  describe "analyze_impact with imports" do
    test "finds impact through import edges (is_a)" do
      # Add entities where B imports A via is_a
      import_source = %{
        id: "chunk_imp_src",
        file_path: "/app/lib/base_service.ex",
        entity_type: :module,
        name: "BaseService",
        content: "defmodule BaseService do\nend",
        start_line: 1,
        end_line: 2,
        module_path: "BaseService",
        visibility: :public,
        parameters: [],
        calls: [],
        is_a: [],
        contains: [],
        language: :elixir
      }

      import_consumer = %{
        id: "chunk_imp_consumer",
        file_path: "/app/lib/derived_service.ex",
        entity_type: :module,
        name: "DerivedService",
        content: "defmodule DerivedService do\nend",
        start_line: 1,
        end_line: 2,
        module_path: "DerivedService",
        visibility: :public,
        parameters: [],
        calls: [],
        is_a: ["BaseService"],
        contains: [],
        language: :elixir
      }

      ChunkCache.insert_many([import_source, import_consumer])
      GraphCache.rebuild_from_chunks(ChunkCache.all())

      {:ok, result} = Queries.analyze_impact("BaseService")

      affected_names = Enum.map(result.impact, & &1.name)
      assert "DerivedService" in affected_names
    end
  end
end
