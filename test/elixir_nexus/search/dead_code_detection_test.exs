defmodule ElixirNexus.Search.DeadCodeDetectionTest do
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

  describe "find_dead_code/1" do
    test "finds public functions with zero callers" do
      {:ok, result} = Queries.find_dead_code()

      dead_names = Enum.map(result.dead_functions, & &1.name)
      # Utils.format is public but never called by anyone
      assert "Utils.format" in dead_names
      # Router.dispatch is public and never called by anyone in our test data
      assert "Router.dispatch" in dead_names
    end

    test "excludes functions that are called" do
      {:ok, result} = Queries.find_dead_code()

      dead_names = Enum.map(result.dead_functions, & &1.name)
      # Server.handle_call is called by Client.call_server
      refute "Server.handle_call" in dead_names
      # Client.call_server is called by Router.dispatch
      refute "Client.call_server" in dead_names
    end

    test "does not flag modules as dead code" do
      {:ok, result} = Queries.find_dead_code()

      dead_types = Enum.map(result.dead_functions, & &1.entity_type)
      # Modules should not appear — only functions/methods
      refute "module" in dead_types
    end

    test "filters by path_prefix" do
      {:ok, result} = Queries.find_dead_code(path_prefix: "/app/lib/utils")

      dead_names = Enum.map(result.dead_functions, & &1.name)
      assert "Utils.format" in dead_names
      # Should not include dead code from other paths
      refute "Router.dispatch" in dead_names
    end

    test "handles qualified name matching" do
      # Add a chunk that calls "format" (unqualified) — should still exclude Utils.format
      extra_chunk = %{
        id: "chunk_format_caller",
        file_path: "/app/lib/formatter.ex",
        entity_type: :function,
        name: "Formatter.run",
        content: "def run(data), do: Utils.format(data)",
        start_line: 1,
        end_line: 1,
        module_path: "Formatter",
        visibility: :public,
        parameters: ["data"],
        calls: ["Utils.format"],
        is_a: [],
        contains: [],
        language: :elixir
      }

      ChunkCache.insert_many([extra_chunk])
      GraphCache.rebuild_from_chunks(ChunkCache.all())

      {:ok, result} = Queries.find_dead_code()
      dead_names = Enum.map(result.dead_functions, & &1.name)
      refute "Utils.format" in dead_names
    end

    test "returns total_public and dead_count" do
      {:ok, result} = Queries.find_dead_code()

      assert is_integer(result.total_public)
      assert is_integer(result.dead_count)
      assert result.dead_count == length(result.dead_functions)
      assert result.total_public >= result.dead_count
    end
  end

  describe "find_dead_code/1 - framework convention filter" do
    @js_chunks [
      %{
        id: "js_get",
        file_path: "/app/app/api/users/route.ts",
        entity_type: :function,
        name: "GET",
        content: "export async function GET() {}",
        start_line: 1,
        end_line: 1,
        module_path: "GET",
        visibility: :public,
        parameters: [],
        calls: [],
        is_a: [],
        contains: [],
        language: :javascript
      },
      %{
        id: "js_post",
        file_path: "/app/app/api/users/route.ts",
        entity_type: :function,
        name: "POST",
        content: "export async function POST() {}",
        start_line: 2,
        end_line: 2,
        module_path: "POST",
        visibility: :public,
        parameters: [],
        calls: [],
        is_a: [],
        contains: [],
        language: :javascript
      },
      %{
        id: "js_default",
        file_path: "/app/app/users/page.tsx",
        entity_type: :function,
        name: "default",
        content: "export default function UsersPage() {}",
        start_line: 1,
        end_line: 1,
        module_path: "default",
        visibility: :public,
        parameters: [],
        calls: [],
        is_a: [],
        contains: [],
        language: :javascript
      },
      %{
        id: "js_real_dead",
        file_path: "/app/app/utils.ts",
        entity_type: :function,
        name: "unusedHelper",
        content: "function unusedHelper() {}",
        start_line: 1,
        end_line: 1,
        module_path: "unusedHelper",
        visibility: :public,
        parameters: [],
        calls: [],
        is_a: [],
        contains: [],
        language: :typescript
      }
    ]

    test "filters GET/POST/default from dead code results for JS/TS files" do
      ChunkCache.clear()
      GraphCache.clear()
      ChunkCache.insert_many(@js_chunks)
      GraphCache.rebuild_from_chunks(@js_chunks)

      {:ok, result} = Queries.find_dead_code()

      dead_names = Enum.map(result.dead_functions, & &1.name)
      refute "GET" in dead_names, "GET should be filtered as framework convention"
      refute "POST" in dead_names, "POST should be filtered as framework convention"
      refute "default" in dead_names, "default should be filtered as framework convention"
    end

    test "still reports genuinely unused JS/TS functions as dead" do
      ChunkCache.clear()
      GraphCache.clear()
      ChunkCache.insert_many(@js_chunks)
      GraphCache.rebuild_from_chunks(@js_chunks)

      {:ok, result} = Queries.find_dead_code()

      dead_names = Enum.map(result.dead_functions, & &1.name)
      assert "unusedHelper" in dead_names
    end

    test "includes warning field for JS/TS projects" do
      ChunkCache.clear()
      GraphCache.clear()
      ChunkCache.insert_many(@js_chunks)
      GraphCache.rebuild_from_chunks(@js_chunks)

      {:ok, result} = Queries.find_dead_code()

      assert is_binary(result.warning), "Expected a warning string for JS/TS project"
      assert String.contains?(result.warning, "framework")
    end

    test "warning is nil for pure Elixir projects" do
      {:ok, result} = Queries.find_dead_code()

      assert is_nil(result.warning), "Expected no warning for Elixir-only project"
    end
  end

  describe "find_dead_code/1 - file convention filtering" do
    @convention_chunks [
      # PascalCase default export from a Next.js page — should NOT be dead code
      %{
        id: "conv_page",
        file_path: "/app/app/users/page.tsx",
        entity_type: :function,
        name: "UsersPage",
        content: "export default function UsersPage() {}",
        start_line: 1,
        end_line: 1,
        module_path: "UsersPage",
        visibility: :public,
        parameters: [],
        calls: [],
        is_a: [],
        contains: [],
        language: :typescript
      },
      # PascalCase default export from a loading skeleton — should NOT be dead code
      %{
        id: "conv_loading",
        file_path: "/app/app/users/loading.tsx",
        entity_type: :function,
        name: "UsersLoading",
        content: "export default function UsersLoading() {}",
        start_line: 1,
        end_line: 1,
        module_path: "UsersLoading",
        visibility: :public,
        parameters: [],
        calls: [],
        is_a: [],
        contains: [],
        language: :typescript
      },
      # PascalCase default export from error boundary — should NOT be dead code
      %{
        id: "conv_error",
        file_path: "/app/app/users/error.tsx",
        entity_type: :function,
        name: "UsersError",
        content: "export default function UsersError() {}",
        start_line: 1,
        end_line: 1,
        module_path: "UsersError",
        visibility: :public,
        parameters: [],
        calls: [],
        is_a: [],
        contains: [],
        language: :typescript
      },
      # PascalCase default export from layout — should NOT be dead code
      %{
        id: "conv_layout",
        file_path: "/app/app/users/layout.tsx",
        entity_type: :function,
        name: "UsersLayout",
        content: "export default function UsersLayout() {}",
        start_line: 1,
        end_line: 1,
        module_path: "UsersLayout",
        visibility: :public,
        parameters: [],
        calls: [],
        is_a: [],
        contains: [],
        language: :typescript
      },
      # PascalCase component in a regular (non-convention) file — SHOULD be dead code
      %{
        id: "conv_widget",
        file_path: "/app/components/widget.tsx",
        entity_type: :function,
        name: "Widget",
        content: "export default function Widget() {}",
        start_line: 1,
        end_line: 1,
        module_path: "Widget",
        visibility: :public,
        parameters: [],
        calls: [],
        is_a: [],
        contains: [],
        language: :typescript
      },
      # Named (camelCase) export from a convention file — SHOULD be dead code if not called
      %{
        id: "conv_helper",
        file_path: "/app/app/users/page.tsx",
        entity_type: :function,
        name: "unusedHelper",
        content: "export function unusedHelper() {}",
        start_line: 5,
        end_line: 5,
        module_path: "unusedHelper",
        visibility: :public,
        parameters: [],
        calls: [],
        is_a: [],
        contains: [],
        language: :typescript
      }
    ]

    setup do
      ChunkCache.clear()
      GraphCache.clear()
      ChunkCache.insert_many(@convention_chunks)
      GraphCache.rebuild_from_chunks(@convention_chunks)
      :ok
    end

    test "excludes PascalCase default exports from convention files (page, loading, error, layout)" do
      {:ok, result} = Queries.find_dead_code()
      dead_names = Enum.map(result.dead_functions, & &1.name)

      refute "UsersPage" in dead_names,
             "PascalCase component from page.tsx should not be dead code"

      refute "UsersLoading" in dead_names,
             "PascalCase component from loading.tsx should not be dead code"

      refute "UsersError" in dead_names,
             "PascalCase component from error.tsx should not be dead code"

      refute "UsersLayout" in dead_names,
             "PascalCase component from layout.tsx should not be dead code"
    end

    test "still flags PascalCase component from non-convention files as dead" do
      {:ok, result} = Queries.find_dead_code()
      dead_names = Enum.map(result.dead_functions, & &1.name)

      assert "Widget" in dead_names,
             "PascalCase component in widget.tsx (not a convention file) should be flagged as dead code"
    end

    test "still flags named exports in convention files as dead if uncalled" do
      {:ok, result} = Queries.find_dead_code()
      dead_names = Enum.map(result.dead_functions, & &1.name)

      assert "unusedHelper" in dead_names,
             "named export in page.tsx should still appear as dead if not called"
    end
  end

  describe "find_dead_code/1 - additional convention files" do
    test "not-found.tsx default export excluded from dead code" do
      chunk = %{
        id: "not_found_page",
        file_path: "/app/app/not-found.tsx",
        entity_type: :function,
        name: "NotFound",
        content: "export default function NotFound() {}",
        start_line: 1,
        end_line: 1,
        module_path: "NotFound",
        visibility: :public,
        parameters: [],
        calls: [],
        is_a: [],
        contains: [],
        language: :typescript
      }

      ChunkCache.clear()
      GraphCache.clear()
      ChunkCache.insert_many([chunk])
      GraphCache.rebuild_from_chunks([chunk])

      {:ok, result} = Queries.find_dead_code()
      dead_names = Enum.map(result.dead_functions, & &1.name)

      refute "NotFound" in dead_names,
             "PascalCase component from not-found.tsx should not be dead code"
    end

    test "route.ts PascalCase default export excluded from dead code" do
      chunk = %{
        id: "route_handler",
        file_path: "/app/app/api/users/route.ts",
        entity_type: :function,
        name: "RouteHandler",
        content: "export default function RouteHandler() {}",
        start_line: 1,
        end_line: 1,
        module_path: "RouteHandler",
        visibility: :public,
        parameters: [],
        calls: [],
        is_a: [],
        contains: [],
        language: :typescript
      }

      ChunkCache.clear()
      GraphCache.clear()
      ChunkCache.insert_many([chunk])
      GraphCache.rebuild_from_chunks([chunk])

      {:ok, result} = Queries.find_dead_code()
      dead_names = Enum.map(result.dead_functions, & &1.name)

      refute "RouteHandler" in dead_names,
             "PascalCase default export from route.ts should not be dead code"
    end
  end
end
