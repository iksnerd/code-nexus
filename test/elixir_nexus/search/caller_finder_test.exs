defmodule ElixirNexus.Search.CallerFinderTest do
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

  describe "find_callers/2 - partial name matching" do
    test "finds callers by short name" do
      {:ok, results} = Queries.find_callers("call_server")
      names = Enum.map(results, fn r -> r.entity["name"] end)
      # Router.dispatch calls Client.call_server
      assert Enum.any?(names, &(&1 != nil))
    end
  end

  describe "find_callers/2 - file_path not null after rebuild_from_chunks" do
    test "callers have non-null file_path" do
      {:ok, results} = Queries.find_callers("handle_call")

      assert results != []

      Enum.each(results, fn r ->
        assert r.entity["file_path"] != nil,
               "Expected file_path to be set, got nil for caller #{r.entity["name"]}"
      end)
    end

    test "callers have correct file_path" do
      {:ok, results} = Queries.find_callers("handle_call")

      paths = Enum.map(results, fn r -> r.entity["file_path"] end)
      # Client.call_server is in client.ex and calls handle_call
      assert "/app/lib/client.ex" in paths
    end
  end

  describe "find_callers/2 - start_line and end_line preserved" do
    test "callers have non-zero start_line from graph cache" do
      {:ok, results} = Queries.find_callers("handle_call")

      assert results != []

      # At least one caller should have a non-zero start_line
      # (graph nodes built via rebuild_from_chunks include line info)
      lines = Enum.map(results, fn r -> r.entity["start_line"] end)

      assert Enum.any?(lines, &(&1 != nil and &1 > 0)),
             "Expected at least one caller with start_line > 0, got: #{inspect(lines)}"
    end
  end

  describe "find_callers/2 - refinement to enclosing function" do
    setup do
      # Module chunk covering lines 1-100, calls "TargetFunc"
      module_chunk = %{
        id: "refine_module",
        file_path: "/app/lib/page.ex",
        entity_type: :module,
        name: "PageModule",
        content: "defmodule PageModule do\nend",
        start_line: 1,
        end_line: 100,
        module_path: "PageModule",
        visibility: :public,
        parameters: [],
        calls: ["TargetFunc"],
        is_a: [],
        contains: ["PageModule.render_page"],
        language: :elixir
      }

      # Function chunk at lines 50-70, also calls "TargetFunc" — should be preferred
      function_chunk = %{
        id: "refine_function",
        file_path: "/app/lib/page.ex",
        entity_type: :function,
        name: "PageModule.render_page",
        content: "def render_page, do: TargetFunc.call()",
        start_line: 50,
        end_line: 70,
        module_path: "PageModule",
        visibility: :public,
        parameters: [],
        calls: ["TargetFunc"],
        is_a: [],
        contains: [],
        language: :elixir
      }

      # The target entity being searched for
      target_chunk = %{
        id: "target_func",
        file_path: "/app/lib/target.ex",
        entity_type: :function,
        name: "TargetFunc",
        content: "def call, do: :ok",
        start_line: 1,
        end_line: 5,
        module_path: "TargetFunc",
        visibility: :public,
        parameters: [],
        calls: [],
        is_a: [],
        contains: [],
        language: :elixir
      }

      ChunkCache.insert_many([module_chunk, function_chunk, target_chunk])
      GraphCache.rebuild_from_chunks(ChunkCache.all())
      :ok
    end

    test "returns function entity instead of module when a tighter match exists" do
      {:ok, results} = Queries.find_callers("TargetFunc")
      assert results != []

      names = Enum.map(results, fn r -> r.entity["name"] end)
      # The enclosing function should be preferred over the module
      assert "PageModule.render_page" in names,
             "Expected render_page in callers, got: #{inspect(names)}"
    end

    test "refined result has proper line numbers (not line 0)" do
      {:ok, results} = Queries.find_callers("TargetFunc")
      assert results != []

      render_result = Enum.find(results, fn r -> r.entity["name"] == "PageModule.render_page" end)

      if render_result do
        assert render_result.entity["start_line"] == 50
        assert render_result.entity["end_line"] == 70
      end
    end
  end
end
