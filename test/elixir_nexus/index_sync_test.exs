defmodule ElixirNexus.IndexSyncTest do
  # Queries bring the index up to date with the disk: a deleted file's functions
  # leave every answer, and a new file goes through the same ignore rules as a
  # reindex. The MCP state is empty in every call, as it is over Streamable HTTP
  # (ExMCP runs each request in a fresh server process).
  use ExUnit.Case, async: false

  alias ElixirNexus.{ChunkCache, GraphCache, Indexer, MCPServer}

  setup do
    :ok = Indexer.await_idle()
    root = Path.join(System.tmp_dir!(), "index_sync_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    on_exit(fn ->
      Indexer.await_idle()
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  defp write(root, rel, content) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  defp index!(root) do
    {:ok, _} = Indexer.index_directory(root)
    :ok = Indexer.await_idle()
    :ok = GraphCache.await_ready(30_000)
  end

  defp tool(name, args \\ %{}) do
    {:ok, %{content: [%{text: json}]}, _} = MCPServer.handle_tool_call(name, args, %{})
    Jason.decode!(json)
  end

  defp indexed_files(root) do
    ChunkCache.file_paths()
    |> Enum.filter(&String.starts_with?(&1, root <> "/"))
    |> Enum.map(&Path.relative_to(&1, root))
  end

  test "a deleted file leaves search, callers, dead code and graph stats", %{root: root} do
    write(root, "lib/app.ex", "defmodule SyncApp do\n  def run(x), do: SyncPaging.fetch_size(x)\nend\n")

    paging =
      write(root, "lib/paging.ex", """
      defmodule SyncPaging do
        def fetch_size(x), do: split(x, 1, 2)
        def split(x, _a, _b), do: x
        def orphan_paging_fn, do: :never_called
      end
      """)

    index!(root)

    assert "lib/paging.ex" in indexed_files(root)
    dead = tool("find_dead_code", %{"path_prefix" => root})
    assert Enum.any?(dead["dead_functions"], &(&1["qualified_name"] == "SyncPaging.orphan_paging_fn/0"))
    assert [_] = tool("find_all_callers", %{"entity_name" => "SyncPaging.split"})
    nodes_before = tool("get_graph_stats")["total_nodes"]

    File.rm!(paging)

    # The first query after the deletion purges the file everywhere.
    dead = tool("find_dead_code", %{"path_prefix" => root})
    refute Enum.any?(dead["dead_functions"] ++ dead["unsure"], &(&1["file_path"] == paging))
    refute "lib/paging.ex" in indexed_files(root)
    assert tool("find_all_callers", %{"entity_name" => "SyncPaging.split"}) == []
    refute Enum.any?(tool("search_code", %{"query" => "orphan_paging_fn"}), &(&1["entity"]["file_path"] == paging))
    assert tool("get_graph_stats")["total_nodes"] < nodes_before
    refute Enum.any?(Map.values(GraphCache.all_nodes()), &(&1["file_path"] == paging))
    refute paging in ElixirNexus.DirtyTracker.known_files()
  end

  test "a file added after the reindex is indexed only when the ignore rules allow it", %{root: root} do
    write(root, ".nexusignore", "/test/\ngenerated/\n")
    write(root, "lib/app.ex", "defmodule SyncIgnApp do\n  def run, do: :ok\nend\n")
    index!(root)
    assert indexed_files(root) == ["lib/app.ex"]

    module = fn name -> "defmodule #{name} do\n  def f, do: :ok\nend\n" end
    write(root, "lib/added.ex", module.("SyncAdded"))
    write(root, "lib/test/helper.ex", module.("SyncNestedTest"))
    write(root, "test/app_test.exs", module.("SyncAppTest"))
    write(root, "lib/generated/out.ex", module.("SyncGenerated"))
    write(root, "generated/top.ex", module.("SyncGeneratedTop"))

    tool("get_graph_stats")

    # Anchored `/test/` drops only the top-level test dir; unanchored
    # `generated/` drops it at every depth.
    assert Enum.sort(indexed_files(root)) == ["lib/added.ex", "lib/app.ex", "lib/test/helper.ex"]
  end

  test "a file that becomes ignored is purged by the next query", %{root: root} do
    write(root, "lib/app.ex", "defmodule SyncLaterApp do\n  def run, do: :ok\nend\n")
    write(root, "scripts/tool.exs", "defmodule SyncLaterScript do\n  def go, do: :ok\nend\n")
    index!(root)
    assert "scripts/tool.exs" in indexed_files(root)

    write(root, ".nexusignore", "/scripts/\n")
    tool("get_graph_stats")

    assert indexed_files(root) == ["lib/app.ex"]
  end

  test "roots recorded for one collection are not used after a switch to another", %{root: root} do
    write(root, "lib/app.ex", "defmodule SyncSwitchApp do\n  def run, do: :ok\nend\n")
    index!(root)
    assert ElixirNexus.IndexScope.roots() == [root]

    original = ElixirNexus.QdrantClient.active_collection()
    ElixirNexus.QdrantClient.switch_collection_force("nexus_force_switched")
    on_exit(fn -> ElixirNexus.QdrantClient.switch_collection_force(original) end)

    assert ElixirNexus.IndexScope.roots() == []
  end
end
