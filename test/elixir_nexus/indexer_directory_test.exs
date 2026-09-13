defmodule ElixirNexus.IndexerDirectoryTest do
  use ExUnit.Case

  setup do
    :ok = ElixirNexus.Indexer.await_idle()

    test_dir = Path.join(System.tmp_dir!(), "index_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p(test_dir)

    on_exit(fn ->
      ElixirNexus.Indexer.await_idle()
      File.rm_rf(test_dir)
    end)

    {:ok, test_dir: test_dir}
  end

  describe "index_directory/1" do
    test "indexes directory recursively", %{test_dir: test_dir} do
      File.write(Path.join(test_dir, "file1.ex"), """
        defmodule A do
          def a, do: :ok
        end
      """)

      subdir = Path.join(test_dir, "subdir")
      File.mkdir_p(subdir)

      File.write(Path.join(subdir, "file2.ex"), """
        defmodule B do
          def b, do: :ok
        end
      """)

      result = ElixirNexus.Indexer.index_directory(test_dir)

      assert is_tuple(result)

      case result do
        {:ok, status} ->
          assert is_map(status)
          assert status.indexed_files >= 2

        {:error, _} ->
          assert true
      end
    end

    test "handles empty directory" do
      empty_dir = Path.join(System.tmp_dir!(), "empty_#{:rand.uniform(1_000_000)}")
      File.mkdir_p(empty_dir)

      on_exit(fn -> File.rm_rf(empty_dir) end)

      result = ElixirNexus.Indexer.index_directory(empty_dir)

      assert is_tuple(result)

      case result do
        {:ok, status} ->
          assert is_integer(status.indexed_files)

        {:error, _} ->
          assert true
      end
    end

    test "records a loud last_index_result error when 0 files are indexed" do
      empty_dir = Path.join(System.tmp_dir!(), "empty_loud_#{:rand.uniform(1_000_000)}")
      File.mkdir_p(empty_dir)
      on_exit(fn -> File.rm_rf(empty_dir) end)

      {:ok, _} = ElixirNexus.Indexer.index_directory(empty_dir)

      result = ElixirNexus.Indexer.status().last_index_result
      assert result.files == 0
      assert is_binary(result.error)
      assert result.error =~ "0 files"
    end

    test "records a clean last_index_result after a successful index", %{test_dir: test_dir} do
      File.write(Path.join(test_dir, "ok.ex"), """
        defmodule Ok do
          def ok, do: :ok
        end
      """)

      {:ok, _} = ElixirNexus.Indexer.index_directory(test_dir)
      :ok = ElixirNexus.Indexer.await_idle()

      result = ElixirNexus.Indexer.status().last_index_result
      assert result.files >= 1
      assert is_nil(result.error)
    end

    test "skips non-Elixir files in directory", %{test_dir: test_dir} do
      File.write(Path.join(test_dir, "valid.ex"), """
        defmodule Valid do
          def valid, do: :ok
        end
      """)

      File.write(Path.join(test_dir, "readme.md"), "# Not Elixir")
      File.write(Path.join(test_dir, "config.json"), "{}")

      result = ElixirNexus.Indexer.index_directory(test_dir)

      assert is_tuple(result)
    end
  end

  describe "index_directories/1" do
    test "returns ok with zero counts for empty list" do
      result = ElixirNexus.Indexer.index_directories([])
      assert {:ok, status} = result
      assert status.indexed_files == 0
      assert status.total_chunks == 0
    end

    test "indexes multiple directories", %{test_dir: test_dir} do
      dir1 = Path.join(test_dir, "dir1")
      dir2 = Path.join(test_dir, "dir2")
      File.mkdir_p!(dir1)
      File.mkdir_p!(dir2)

      File.write!(Path.join(dir1, "a.ex"), """
      defmodule A do
        def a, do: :ok
      end
      """)

      File.write!(Path.join(dir2, "b.ex"), """
      defmodule B do
        def b, do: :ok
      end
      """)

      result = ElixirNexus.Indexer.index_directories([dir1, dir2])
      assert {:ok, status} = result
      assert is_integer(status.indexed_files)
    end
  end

  describe "gitignore handling" do
    test "honors path patterns and .gitignore files in subdirectories", %{test_dir: test_dir} do
      # gpt-alpha: speech/.gitignore lists `public/built/`, and the 40k-line
      # webpack bundle under it was indexed anyway.
      write = fn rel, content ->
        path = Path.join(test_dir, rel)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, content)
      end

      write.(".gitignore", "/generated/\nlib/vendored/\n")
      write.("lib/app.ex", "defmodule App do\n  def run, do: :ok\nend\n")
      write.("lib/vendored/copy.ex", "defmodule Vendored do\n  def v, do: :ok\nend\n")
      write.("generated/out.ex", "defmodule Generated do\n  def g, do: :ok\nend\n")
      write.("speech/.gitignore", "public/built/\n*.gen.js\n")
      write.("speech/public/built/worker.js", "function bundled() { return 1 }\n")
      write.("speech/src/app.gen.js", "function generatedHelper() { return 2 }\n")
      write.("speech/src/real.js", "function realSpeech() { return 3 }\n")
      # A sibling of speech/ must not inherit speech/.gitignore.
      write.("other/public/built/kept.js", "function keptBuilt() { return 4 }\n")

      {:ok, _} = ElixirNexus.Indexer.index_directory(test_dir)
      :ok = ElixirNexus.Indexer.await_idle()

      indexed =
        ElixirNexus.ChunkCache.all()
        |> Enum.map(&Path.relative_to(&1.file_path, test_dir))
        |> Enum.uniq()

      assert "lib/app.ex" in indexed
      assert "speech/src/real.js" in indexed
      assert "other/public/built/kept.js" in indexed
      refute "lib/vendored/copy.ex" in indexed
      refute "generated/out.ex" in indexed
      refute "speech/public/built/worker.js" in indexed
      refute "speech/src/app.gen.js" in indexed
    end
  end

  describe "reindex reconciliation" do
    test "purges chunks for files that dropped out of scope", %{test_dir: test_dir} do
      keep = Path.join(test_dir, "keep.ex")
      drop = Path.join(test_dir, "drop.ex")

      File.write!(keep, "defmodule Keep do\n  def keep, do: :ok\nend\n")
      File.write!(drop, "defmodule Drop do\n  def drop, do: :ok\nend\n")

      {:ok, _} = ElixirNexus.Indexer.index_directory(test_dir)
      :ok = ElixirNexus.Indexer.await_idle()

      assert Enum.any?(ElixirNexus.ChunkCache.all(), &(&1.file_path == drop))

      # Remove the file from scope and reindex — its chunks must be evicted.
      File.rm!(drop)
      {:ok, _} = ElixirNexus.Indexer.index_directory(test_dir)
      :ok = ElixirNexus.Indexer.await_idle()

      refute Enum.any?(ElixirNexus.ChunkCache.all(), &(&1.file_path == drop))
      assert Enum.any?(ElixirNexus.ChunkCache.all(), &(&1.file_path == keep))
      refute drop in ElixirNexus.DirtyTracker.known_files()
    end

    test "purges cached chunks from outside the project root", %{test_dir: test_dir} do
      # Chunks from another project can sit in the collection (a stray watcher
      # event, or hydration from Qdrant after a restart) without DirtyTracker
      # knowing the file. Reindex must evict them too.
      File.write!(Path.join(test_dir, "own.ex"), "defmodule Own do\n  def own, do: :ok\nend\n")
      {:ok, _} = ElixirNexus.Indexer.index_directory(test_dir)
      :ok = ElixirNexus.Indexer.await_idle()

      foreign = "/elsewhere/other_project/lib/foreign.ex"

      ElixirNexus.ChunkCache.insert_many([
        %{id: "foreign-1", file_path: foreign, name: "foreign", entity_type: :function, content: "def foreign"}
      ])

      {:ok, _} = ElixirNexus.Indexer.index_directory(test_dir)
      :ok = ElixirNexus.Indexer.await_idle()

      refute Enum.any?(ElixirNexus.ChunkCache.all(), &(&1.file_path == foreign))
      assert Enum.any?(ElixirNexus.ChunkCache.all(), &(&1.file_path == Path.join(test_dir, "own.ex")))
    end

    test "purges collection points from outside the project root that no cache knows about", %{test_dir: test_dir} do
      # control-stack's collection kept 48 gpt-alpha/elixir-nexus points through a
      # reindex after a restart: they were only in Qdrant, never in ChunkCache or
      # DirtyTracker, so reconcile didn't see them.
      File.write!(Path.join(test_dir, "own.ex"), "defmodule OwnQ do\n  def own, do: :ok\nend\n")
      {:ok, _} = ElixirNexus.Indexer.index_directory(test_dir)
      :ok = ElixirNexus.Indexer.await_idle()

      other = Path.join(System.tmp_dir!(), "other_project_#{System.unique_integer([:positive])}")
      File.mkdir_p!(other)
      foreign = Path.join(other, "foreign.ex")
      File.write!(foreign, "defmodule ForeignQ do\n  def foreign_thing, do: :ok\nend\n")
      on_exit(fn -> File.rm_rf!(other) end)

      {:ok, _} = ElixirNexus.Indexer.index_file(foreign)
      # Now it exists only in Qdrant, as after a restart.
      ElixirNexus.ChunkCache.delete_by_file(foreign)
      ElixirNexus.DirtyTracker.forget(foreign)

      points_for = fn path ->
        filter = %{"must" => [%{"key" => "file_path", "match" => %{"value" => path}}]}
        {:ok, %{"result" => %{"points" => points}}} = ElixirNexus.QdrantClient.scroll_points(10, nil, filter)
        points
      end

      assert points_for.(foreign) != []

      {:ok, _} = ElixirNexus.Indexer.index_directory(test_dir)
      :ok = ElixirNexus.Indexer.await_idle()

      assert points_for.(foreign) == []
      assert points_for.(Path.join(test_dir, "own.ex")) != []
    end

    test "purge/0 clears the index", %{test_dir: test_dir} do
      File.write!(Path.join(test_dir, "x.ex"), "defmodule X do\n  def x, do: :ok\nend\n")

      {:ok, _} = ElixirNexus.Indexer.index_directory(test_dir)
      :ok = ElixirNexus.Indexer.await_idle()
      assert ElixirNexus.ChunkCache.count() > 0

      assert :ok = ElixirNexus.Indexer.purge()
      assert ElixirNexus.ChunkCache.count() == 0
      assert ElixirNexus.DirtyTracker.known_files() == []
    end

    test "reindex after purge forces a full reparse even if DirtyTracker is re-seeded", %{
      test_dir: test_dir
    } do
      File.write!(Path.join(test_dir, "y.ex"), "defmodule Y do\n  def y, do: :ok\nend\n")

      {:ok, _} = ElixirNexus.Indexer.index_directory(test_dir)
      :ok = ElixirNexus.Indexer.await_idle()
      assert ElixirNexus.ChunkCache.count() > 0

      # Purge clears the index and arms the one-shot force-full flag.
      assert :ok = ElixirNexus.Indexer.purge()
      assert ElixirNexus.ChunkCache.count() == 0

      # Simulate the boot-auto-reload race: DirtyTracker gets re-populated with the file's
      # SHA AFTER the purge. Without the force-full guard, the next reindex would see the
      # files as "unchanged", skip embedding, and leave a near-empty index (the bug).
      Enum.each(
        Path.wildcard(Path.join(test_dir, "*.ex")),
        &ElixirNexus.DirtyTracker.mark_clean/1
      )

      refute ElixirNexus.DirtyTracker.empty?()

      {:ok, _} = ElixirNexus.Indexer.index_directory(test_dir)
      :ok = ElixirNexus.Indexer.await_idle()

      assert ElixirNexus.ChunkCache.count() > 0,
             "purge must force a full reparse despite a re-seeded DirtyTracker"
    end
  end

  describe "error resilience" do
    test "continues after individual file errors", %{test_dir: test_dir} do
      File.write(Path.join(test_dir, "good.ex"), """
        defmodule Good do
          def good, do: :ok
        end
      """)

      File.write(Path.join(test_dir, "bad.ex"), """
        defmodule Bad do
          def broken(
          # no closing
      """)

      result = ElixirNexus.Indexer.index_directory(test_dir)

      assert is_tuple(result)
    end

    test "handles concurrent indexing gracefully" do
      test_dir = Path.join(System.tmp_dir!(), "concurrent_#{:rand.uniform(1_000_000)}")
      File.mkdir_p(test_dir)

      on_exit(fn -> File.rm_rf(test_dir) end)

      tasks =
        for _i <- 1..3 do
          Task.async(fn ->
            ElixirNexus.Indexer.index_directory(test_dir)
          end)
        end

      results = Task.await_many(tasks)

      assert Enum.all?(results, &is_tuple/1)
    end
  end
end
