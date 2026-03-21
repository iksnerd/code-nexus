defmodule ElixirNexus.IndexingProducerTest do
  use ExUnit.Case, async: false

  alias ElixirNexus.IndexingProducer

  describe "push/1" do
    test "pushes files to producer" do
      result = IndexingProducer.push(["file1.ex", "file2.ex"])
      assert result == :ok
    end

    test "pushes empty list without error" do
      result = IndexingProducer.push([])
      assert result == :ok
    end

    test "pushes single file" do
      result = IndexingProducer.push(["single_file.ts"])
      assert result == :ok
    end
  end

  describe "producer registration" do
    test "producer is registered in Registry" do
      result = Registry.lookup(ElixirNexus.Registry, ElixirNexus.IndexingProducer)
      assert [{pid, :producer}] = result
      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end
end
