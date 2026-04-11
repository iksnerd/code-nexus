defmodule ElixirNexus.Search.ModuleHierarchyTest do
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

  describe "find_module_hierarchy/1 - unresolvable parents" do
    test "marks unresolvable parents as resolved: false" do
      {:ok, result} = Queries.find_module_hierarchy("Server")

      # GenServer is in is_a but not in our test chunks as an entity
      gen_server_parent = Enum.find(result.parents, &(&1.name == "GenServer"))
      assert gen_server_parent != nil
      assert gen_server_parent.resolved == false
    end
  end

  describe "find_module_hierarchy multi-strategy" do
    test "matches by file path basename" do
      # Add an entity with a file path that matches via normalize
      path_chunk = %{
        id: "chunk_billing_page",
        file_path: "/app/components/billing-page.tsx",
        entity_type: :module,
        name: "default",
        content: "export default function BillingPage() {}",
        start_line: 1,
        end_line: 1,
        module_path: "default",
        visibility: :public,
        parameters: [],
        calls: [],
        is_a: [],
        contains: [],
        language: :typescript
      }

      ChunkCache.insert_many([path_chunk])
      GraphCache.rebuild_from_chunks(ChunkCache.all())

      {:ok, result} = Queries.find_module_hierarchy("BillingPage")
      # Should find via file path basename normalization (billing-page -> billingpage == BillingPage -> billingpage)
      assert result.file_path == "/app/components/billing-page.tsx"
    end

    test "matches by substring" do
      # Add an entity with a longer name that contains the query
      substr_chunk = %{
        id: "chunk_billing_comp",
        file_path: "/app/components/billing.tsx",
        entity_type: :function,
        name: "BillingPageComponent",
        content: "function BillingPageComponent() {}",
        start_line: 1,
        end_line: 1,
        module_path: "BillingPageComponent",
        visibility: :public,
        parameters: [],
        calls: [],
        is_a: [],
        contains: [],
        language: :typescript
      }

      ChunkCache.insert_many([substr_chunk])
      GraphCache.rebuild_from_chunks(ChunkCache.all())

      {:ok, result} = Queries.find_module_hierarchy("BillingPage")
      # Should find via substring match
      assert String.contains?(result.name, "BillingPage")
    end
  end

  describe "find_module_hierarchy/1 - @/ path alias resolution" do
    setup do
      button_chunk = %{
        id: "button_chunk",
        file_path: "/app/src/components/ui/button.tsx",
        entity_type: :function,
        name: "Button",
        content: "export function Button() {}",
        start_line: 1,
        end_line: 10,
        module_path: "Button",
        visibility: :public,
        parameters: [],
        calls: [],
        is_a: [],
        contains: [],
        language: :typescript
      }

      page_chunk = %{
        id: "page_chunk",
        file_path: "/app/src/app/page.tsx",
        entity_type: :function,
        name: "HomePage",
        content: "import { Button } from '@/components/ui/button';\nexport function HomePage() {}",
        start_line: 1,
        end_line: 20,
        module_path: "HomePage",
        visibility: :public,
        parameters: [],
        calls: ["Button"],
        is_a: ["@/components/ui/button"],
        contains: [],
        language: :typescript
      }

      ChunkCache.insert_many([button_chunk, page_chunk])
      GraphCache.rebuild_from_chunks(ChunkCache.all())
      :ok
    end

    test "resolves @/ prefixed import to entity file path" do
      {:ok, result} = Queries.find_module_hierarchy("HomePage")
      assert result.name == "HomePage"

      # The @/components/ui/button import should resolve to the Button entity
      resolved_parents = Enum.filter(result.parents, & &1.resolved)

      assert resolved_parents != [],
             "Expected at least one resolved parent, got: #{inspect(result.parents)}"

      resolved_names = Enum.map(resolved_parents, & &1.name)

      assert "Button" in resolved_names,
             "Expected Button in resolved parents, got: #{inspect(resolved_names)}"
    end

    test "resolved parent includes file_path" do
      {:ok, result} = Queries.find_module_hierarchy("HomePage")
      button_parent = Enum.find(result.parents, fn p -> p[:name] == "Button" end)

      if button_parent && button_parent.resolved do
        assert button_parent.file_path == "/app/src/components/ui/button.tsx"
      end
    end
  end
end
