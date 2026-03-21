defmodule ElixirNexus.IndexingPipelineTest do
  use ExUnit.Case, async: false

  alias ElixirNexus.IndexingPipeline

  describe "transform/2" do
    test "wraps event in Broadway.Message" do
      msg = IndexingPipeline.transform("test/file.ex", [])
      assert %Broadway.Message{data: "test/file.ex"} = msg
      assert msg.acknowledger == {IndexingPipeline, :ack_id, :ack_data}
    end

    test "preserves the file path as message data" do
      path = "/some/deep/nested/file.ts"
      msg = IndexingPipeline.transform(path, [])
      assert msg.data == path
    end

    test "ignores opts parameter" do
      msg1 = IndexingPipeline.transform("file.ex", [])
      msg2 = IndexingPipeline.transform("file.ex", [some: :option])
      assert msg1.data == msg2.data
      assert msg1.acknowledger == msg2.acknowledger
    end
  end

  describe "ack/3" do
    test "returns :ok with empty lists" do
      assert :ok = IndexingPipeline.ack(:ack_id, [], [])
    end

    test "returns :ok regardless of arguments" do
      assert :ok = IndexingPipeline.ack(:ack_id, [:msg1, :msg2], [:failed1])
    end
  end

  describe "pipeline process" do
    test "Broadway pipeline is running" do
      assert Process.whereis(ElixirNexus.IndexingPipeline) != nil
    end

    test "pipeline process is alive" do
      pid = Process.whereis(ElixirNexus.IndexingPipeline)
      assert Process.alive?(pid)
    end
  end
end
