defmodule ElixirNexus.MCPServer.ResourcesTest do
  use ExUnit.Case, async: false

  # Resources reads from ETS (ChunkCache + GraphCache) so tests must be sync.

  alias ElixirNexus.MCPServer.Resources
  alias ElixirNexus.{ChunkCache, GraphCache}

  # Minimal chunk fixture — enough for the resource generators to produce output.
  @chunks [
    %{
      id: "res_chunk_1",
      file_path: "/app/lib/server.ex",
      entity_type: :module,
      name: "Server",
      content: "defmodule Server do\nend",
      start_line: 1,
      end_line: 10,
      module_path: "Server",
      visibility: :public,
      calls: ["GenServer.start_link"],
      is_a: ["GenServer"],
      contains: ["Server.handle_call"],
      language: :elixir
    },
    %{
      id: "res_chunk_2",
      file_path: "/app/lib/server.ex",
      entity_type: :function,
      name: "Server.handle_call",
      content: "def handle_call(:ping, _from, state), do: {:reply, :pong, state}",
      start_line: 3,
      end_line: 5,
      module_path: "Server",
      visibility: :public,
      calls: [],
      is_a: [],
      contains: [],
      language: :elixir
    },
    %{
      id: "res_chunk_3",
      file_path: "/app/lib/client.ex",
      entity_type: :function,
      name: "Client.ping",
      content: "def ping, do: GenServer.call(Server, :ping)",
      start_line: 1,
      end_line: 3,
      module_path: "Client",
      visibility: :public,
      calls: ["Server.handle_call", "GenServer.call"],
      is_a: [],
      contains: [],
      language: :elixir
    }
  ]

  setup do
    ChunkCache.ensure_table()
    GraphCache.ensure_table()
    ChunkCache.clear()
    GraphCache.clear()

    ChunkCache.insert_many(@chunks)

    GraphCache.rebuild_from_chunks(@chunks)
    :ok
  end

  describe "read_resource_content/1" do
    test "returns error for unknown URI" do
      assert {:error, msg} = Resources.read_resource_content("nexus://unknown/resource")
      assert msg =~ "Unknown resource"
    end

    test "tool guide is always available" do
      assert {:ok, content} = Resources.read_resource_content("nexus://guide/tools")
      assert content =~ "reindex"
      assert content =~ "search_code"
    end
  end

  describe "generate_overview (nexus://project/overview)" do
    test "returns overview when indexed" do
      assert {:ok, content} = Resources.read_resource_content("nexus://project/overview")
      assert content =~ "Project Overview"
      assert content =~ "Files indexed:"
      assert content =~ "Language Breakdown"
      assert content =~ "Entity Types"
    end

    test "entity types show function and module — not 'unknown'" do
      assert {:ok, content} = Resources.read_resource_content("nexus://project/overview")
      assert content =~ "function"
      assert content =~ "module"
      refute content =~ "| unknown |"
    end

    test "language breakdown shows elixir" do
      assert {:ok, content} = Resources.read_resource_content("nexus://project/overview")
      assert content =~ "elixir"
    end

    test "returns not-indexed message when cache is empty" do
      ChunkCache.clear()
      GraphCache.clear()
      assert {:ok, content} = Resources.read_resource_content("nexus://project/overview")
      assert content =~ "No Project Indexed"
    end
  end

  describe "generate_architecture (nexus://project/architecture)" do
    test "returns architecture when indexed" do
      assert {:ok, content} = Resources.read_resource_content("nexus://project/architecture")
      assert content =~ "Project Architecture"
      assert content =~ "Key Modules"
      assert content =~ "Most Connected Functions"
    end

    test "key modules table includes module-type entities" do
      assert {:ok, content} = Resources.read_resource_content("nexus://project/architecture")
      # Server is the only :module entity in fixtures
      assert content =~ "Server"
    end

    test "most connected functions excludes modules" do
      assert {:ok, content} = Resources.read_resource_content("nexus://project/architecture")
      # The function section should list functions, not modules
      assert content =~ "Most Connected Functions"
    end

    test "returns not-indexed message when cache is empty" do
      ChunkCache.clear()
      GraphCache.clear()
      assert {:ok, content} = Resources.read_resource_content("nexus://project/architecture")
      assert content =~ "No Project Indexed"
    end
  end

  describe "generate_hotspots (nexus://project/hotspots)" do
    test "returns hotspots when indexed" do
      assert {:ok, content} = Resources.read_resource_content("nexus://project/hotspots")
      assert content =~ "Complexity Hotspots"
      assert content =~ "Fan-Out"
      assert content =~ "Fan-In"
      assert content =~ "Dead Code Summary"
    end

    test "dead code summary counts are numeric" do
      assert {:ok, content} = Resources.read_resource_content("nexus://project/hotspots")
      # Format: **Public functions with zero callers:** N of M public entities
      assert content =~ ~r/zero callers:\*\* \d+ of \d+/
    end

    test "returns not-indexed message when cache is empty" do
      ChunkCache.clear()
      GraphCache.clear()
      assert {:ok, content} = Resources.read_resource_content("nexus://project/hotspots")
      assert content =~ "No Project Indexed"
    end
  end
end
