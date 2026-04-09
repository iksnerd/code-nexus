defmodule ElixirNexus.GraphCacheTest do
  use ExUnit.Case, async: false

  alias ElixirNexus.GraphCache

  @table :nexus_graph_cache

  setup do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])
    end

    GraphCache.clear()
    :ok
  end

  describe "put_node/2 and get_node/1" do
    test "stores and retrieves a node" do
      node = %{"name" => "foo", "calls" => ["bar"], "is_a" => [], "contains" => []}
      GraphCache.put_node("foo_id", node)

      assert GraphCache.get_node("foo_id") == node
    end

    test "returns nil for missing node" do
      assert GraphCache.get_node("missing") == nil
    end

    test "overwrites existing node" do
      GraphCache.put_node("id1", %{"name" => "v1"})
      GraphCache.put_node("id1", %{"name" => "v2"})
      assert GraphCache.get_node("id1") == %{"name" => "v2"}
    end
  end

  describe "all_nodes/0" do
    test "returns all nodes as a map" do
      GraphCache.put_node("a", %{"name" => "alpha"})
      GraphCache.put_node("b", %{"name" => "beta"})

      nodes = GraphCache.all_nodes()
      assert map_size(nodes) == 2
      assert nodes["a"]["name"] == "alpha"
      assert nodes["b"]["name"] == "beta"
    end

    test "returns empty map when cache is empty" do
      assert GraphCache.all_nodes() == %{}
    end
  end

  describe "find_callers/1" do
    test "finds nodes that call a given entity" do
      GraphCache.put_node("caller1", %{"name" => "caller1", "calls" => ["target_func"], "is_a" => [], "contains" => []})
      GraphCache.put_node("caller2", %{"name" => "caller2", "calls" => ["other_func"], "is_a" => [], "contains" => []})
      GraphCache.put_node("target", %{"name" => "target_func", "calls" => [], "is_a" => [], "contains" => []})

      callers = GraphCache.find_callers("target_func")
      assert length(callers) == 1
      {_id, node} = hd(callers)
      assert node["name"] == "caller1"
    end

    test "case insensitive matching" do
      GraphCache.put_node("c1", %{"name" => "c1", "calls" => ["MyModule"], "is_a" => [], "contains" => []})
      callers = GraphCache.find_callers("mymodule")
      assert length(callers) == 1
    end

    test "returns empty list when no callers" do
      GraphCache.put_node("lonely", %{"name" => "lonely", "calls" => [], "is_a" => [], "contains" => []})
      assert GraphCache.find_callers("lonely") == []
    end
  end

  describe "update_file/2" do
    test "removes old entries for file and inserts new ones" do
      # Insert initial entries
      GraphCache.put_node("old1", %{"name" => "old1", "file_path" => "lib/foo.ex"})
      GraphCache.put_node("old2", %{"name" => "old2", "file_path" => "lib/foo.ex"})
      GraphCache.put_node("keep", %{"name" => "keep", "file_path" => "lib/bar.ex"})

      assert map_size(GraphCache.all_nodes()) == 3

      # Update the file with new chunks
      new_chunks = [
        %{
          id: nil,
          name: "new1",
          entity_type: :function,
          file_path: "lib/foo.ex",
          calls: ["keep"],
          is_a: [],
          contains: []
        }
      ]

      GraphCache.update_file("lib/foo.ex", new_chunks)

      nodes = GraphCache.all_nodes()
      # old1 and old2 removed, keep stays, new1 added
      assert map_size(nodes) == 2
      assert nodes["keep"] != nil
      assert nodes["new1"] != nil
    end
  end

  describe "clear/0" do
    test "removes all entries" do
      GraphCache.put_node("a", %{"name" => "a"})
      GraphCache.put_node("b", %{"name" => "b"})
      assert map_size(GraphCache.all_nodes()) == 2

      GraphCache.clear()
      assert GraphCache.all_nodes() == %{}
    end
  end
end
