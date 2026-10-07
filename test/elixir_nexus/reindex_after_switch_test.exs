defmodule ElixirNexus.ReindexAfterSwitchTest do
  # Indexing project B between two reindexes of project A must not make A's
  # unchanged files look changed: the caches and checksums in memory belong to
  # B then, and A's collection already holds A's chunks and checksums.
  use ExUnit.Case, async: false

  alias ElixirNexus.{Indexer, MCPServer.IndexManagement, QdrantClient}

  setup do
    :ok = Indexer.await_idle()
    original = QdrantClient.active_collection()
    n = System.unique_integer([:positive])
    a = Path.join(System.tmp_dir!(), "reembed_test_a_#{n}")
    b = Path.join(System.tmp_dir!(), "reembed_test_b_#{n}")

    for {dir, mod} <- [{a, "ReembedA"}, {b, "ReembedB"}], i <- 1..3 do
      File.mkdir_p!(Path.join(dir, "lib"))
      File.write!(Path.join(dir, "lib/f#{i}.ex"), "defmodule #{mod}#{i} do\n  def f#{i}(x), do: x\nend\n")
    end

    handler = "reembed-#{n}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:nexus, :pipeline, :file_parsed],
      fn _event, _measurements, %{file: file}, _ -> send(test_pid, {:parsed, file}) end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler)
      Indexer.await_idle()

      for dir <- [a, b] do
        QdrantClient.delete_collection("nexus_" <> Path.basename(dir))
        File.rm_rf!(dir)
      end

      QdrantClient.switch_collection_force(original)
    end)

    {:ok, a: a, b: b}
  end

  defp index!(dir) do
    IndexManagement.ensure_collection_for_project(dir)
    {:ok, reply} = Indexer.index_directory(dir)
    :ok = Indexer.await_idle()
    reply
  end

  defp parsed_files do
    receive do
      {:parsed, file} -> [file | parsed_files()]
    after
      200 -> []
    end
  end

  test "switching to another project and back re-embeds only what changed", %{a: a, b: b} do
    index!(a)
    assert length(parsed_files()) == 3
    # The caches say whose chunks they hold.
    assert ElixirNexus.ChunkCache.collection() == QdrantClient.active_collection()

    index!(b)
    assert length(parsed_files()) == 3

    reply = index!(a)
    assert parsed_files() == []
    # Every file of A is still answered from the cache, none of B's.
    assert reply.indexed_files == 3
    assert ElixirNexus.ChunkCache.file_paths() |> Enum.map(&Path.dirname(Path.dirname(&1))) |> Enum.uniq() == [a]

    edited = Path.join(a, "lib/f2.ex")
    File.write!(edited, "defmodule ReembedA2 do\n  def f2(x), do: {x, :edited}\nend\n")
    index!(b)
    parsed_files()

    index!(a)
    assert parsed_files() == [edited]
  end

  test "a file stored by an older parser is still parsed again after a switch back", %{a: a, b: b} do
    # B exists first, so the switch to it below is incremental and keeps no
    # checksum of A's in memory that could hide the stale file.
    index!(b)
    index!(a)
    parsed_files()

    # As if f3's chunks had been stored before the last index_version bump.
    old = Path.join(a, "lib/f3.ex")
    %{url: url, collection: collection} = Application.get_env(:elixir_nexus, :qdrant_runtime)

    {:ok, %{status_code: 200}} =
      HTTPoison.post(
        "#{url}/collections/#{collection}/points/payload?wait=true",
        Jason.encode!(%{
          payload: %{index_version: ElixirNexus.IndexingHelpers.index_version() - 1},
          filter: %{must: [%{key: "file_path", match: %{value: old}}]}
        }),
        [{"content-type", "application/json"}]
      )

    index!(b)
    parsed_files()

    index!(a)
    assert parsed_files() == [old]
  end
end
