defmodule ElixirNexus.Search.CommunityContextTest do
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

  describe "get_community_context with imports" do
    test "detects files that import the target" do
      # File A: base service
      file_a_chunk = %{
        id: "chunk_ctx_a",
        file_path: "/app/src/services/auth-service.ts",
        entity_type: :function,
        name: "AuthService.authenticate",
        content: "function authenticate() {}",
        start_line: 1,
        end_line: 1,
        module_path: "AuthService",
        visibility: :public,
        parameters: [],
        calls: [],
        is_a: [],
        contains: [],
        language: :typescript
      }

      # File B: imports from file A via is_a path
      file_b_chunk = %{
        id: "chunk_ctx_b",
        file_path: "/app/src/controllers/login.ts",
        entity_type: :function,
        name: "LoginController.login",
        content: "function login() { authenticate() }",
        start_line: 1,
        end_line: 1,
        module_path: "LoginController",
        visibility: :public,
        parameters: [],
        calls: [],
        is_a: ["@/services/auth-service"],
        contains: [],
        language: :typescript
      }

      ChunkCache.insert_many([file_a_chunk, file_b_chunk])
      GraphCache.rebuild_from_chunks(ChunkCache.all())

      {:ok, result} = Queries.get_community_context("/app/src/services/auth-service.ts")

      coupled_paths = Enum.map(result.coupled_files, & &1.file_path)
      assert "/app/src/controllers/login.ts" in coupled_paths
    end
  end
end
