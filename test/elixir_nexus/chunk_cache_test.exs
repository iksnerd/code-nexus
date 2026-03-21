defmodule ElixirNexus.ChunkCacheTest do
  use ExUnit.Case, async: false

  alias ElixirNexus.ChunkCache

  @table :nexus_chunk_cache

  setup do
    # Ensure table exists (CacheOwner may or may not be running)
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:bag, :public, :named_table, read_concurrency: true, write_concurrency: true])
    end

    ChunkCache.clear()
    :ok
  end

  defp make_chunk(opts) do
    %{
      id: Keyword.get(opts, :id, "abc123"),
      file_path: Keyword.get(opts, :file_path, "lib/foo.ex"),
      entity_type: Keyword.get(opts, :entity_type, :function),
      name: Keyword.get(opts, :name, "my_func"),
      content: Keyword.get(opts, :content, "def my_func, do: :ok"),
      start_line: Keyword.get(opts, :start_line, 1),
      end_line: Keyword.get(opts, :end_line, 1),
      docstring: nil,
      module_path: nil,
      parameters: [],
      visibility: :public,
      calls: Keyword.get(opts, :calls, []),
      is_a: [],
      contains: [],
      language: :elixir
    }
  end

  describe "insert_many/1" do
    test "inserts chunks into ETS" do
      chunks = [make_chunk(id: "a1", name: "foo"), make_chunk(id: "a2", name: "bar")]
      assert :ok = ChunkCache.insert_many(chunks)
      assert ChunkCache.count() == 2
    end
  end

  describe "count/0" do
    test "returns 0 for empty table" do
      assert ChunkCache.count() == 0
    end

    test "returns correct count after inserts" do
      ChunkCache.insert_many([make_chunk(id: "c1"), make_chunk(id: "c2"), make_chunk(id: "c3")])
      assert ChunkCache.count() == 3
    end
  end

  describe "search/2" do
    test "finds chunks by name" do
      ChunkCache.insert_many([
        make_chunk(id: "s1", name: "process_file"),
        make_chunk(id: "s2", name: "parse_ast"),
        make_chunk(id: "s3", name: "embed_text")
      ])

      results = ChunkCache.search("process", 10)
      assert length(results) == 1
      assert hd(results).entity["name"] == "process_file"
    end

    test "finds chunks by content" do
      ChunkCache.insert_many([
        make_chunk(id: "s4", name: "foo", content: "def foo, do: Logger.info(\"hello\")")
      ])

      results = ChunkCache.search("logger", 10)
      assert length(results) == 1
    end

    test "respects limit" do
      chunks = for i <- 1..20, do: make_chunk(id: "l#{i}", name: "func_#{i}", content: "def func_#{i}, do: :ok")
      ChunkCache.insert_many(chunks)

      results = ChunkCache.search("func", 5)
      assert length(results) == 5
    end

    test "case insensitive search" do
      ChunkCache.insert_many([make_chunk(id: "ci1", name: "MyModule")])
      results = ChunkCache.search("mymodule", 10)
      assert length(results) == 1
    end

    test "returns empty list for no matches" do
      ChunkCache.insert_many([make_chunk(id: "nm1", name: "foo")])
      results = ChunkCache.search("zzz_nonexistent", 10)
      assert results == []
    end
  end

  describe "delete_by_file/1" do
    test "removes all chunks for a file" do
      ChunkCache.insert_many([
        make_chunk(id: "d1", file_path: "lib/a.ex", name: "a1"),
        make_chunk(id: "d2", file_path: "lib/a.ex", name: "a2"),
        make_chunk(id: "d3", file_path: "lib/b.ex", name: "b1")
      ])

      assert ChunkCache.count() == 3
      ChunkCache.delete_by_file("lib/a.ex")
      assert ChunkCache.count() == 1
    end
  end

  describe "all/0" do
    test "returns all chunks" do
      chunks = [make_chunk(id: "a1", name: "x"), make_chunk(id: "a2", name: "y")]
      ChunkCache.insert_many(chunks)

      all = ChunkCache.all()
      assert length(all) == 2
      names = Enum.map(all, & &1.name) |> Enum.sort()
      assert names == ["x", "y"]
    end
  end

  describe "clear/0" do
    test "removes all entries" do
      ChunkCache.insert_many([make_chunk(id: "cl1"), make_chunk(id: "cl2")])
      assert ChunkCache.count() == 2
      ChunkCache.clear()
      assert ChunkCache.count() == 0
    end
  end
end
