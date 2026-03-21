defmodule ElixirNexus.CacheOwnerTest do
  use ExUnit.Case, async: true

  describe "ETS tables" do
    test "GraphCache table exists and is public" do
      table = ElixirNexus.GraphCache.table_name()
      info = :ets.info(table)
      assert info != :undefined
      assert info[:protection] == :public
      assert info[:type] == :set
    end

    test "ChunkCache table exists and is public bag" do
      table = ElixirNexus.ChunkCache.table_name()
      info = :ets.info(table)
      assert info != :undefined
      assert info[:protection] == :public
      assert info[:type] == :bag
    end
  end
end
