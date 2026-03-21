defmodule ElixirNexus.ChunkerTest do
  use ExUnit.Case

  alias ElixirNexus.Chunker
  alias ElixirNexus.CodeSchema

  @sample_entity %CodeSchema{
    file_path: "lib/test.ex",
    entity_type: :function,
    name: "process_data",
    content: "def process_data(input), do: transform(input)",
    start_line: 10,
    end_line: 10,
    parameters: ["input"],
    visibility: :public,
    calls: ["transform"],
    is_a: [],
    contains: []
  }

  describe "prepare_for_embedding/1" do
    test "includes file, type, and name context" do
      chunk = hd(Chunker.chunk_entity(@sample_entity))
      text = Chunker.prepare_for_embedding(chunk)

      assert String.contains?(text, "lib/test.ex")
      assert String.contains?(text, "function")
      assert String.contains?(text, "process_data")
      assert String.contains?(text, "def process_data")
    end
  end

  describe "prepare_for_keywords/1" do
    test "boosts entity name for keyword matching" do
      chunk = hd(Chunker.chunk_entity(@sample_entity))
      text = Chunker.prepare_for_keywords(chunk)

      # Name should appear multiple times for boosting
      name_count =
        text
        |> String.split("process_data")
        |> length()
        |> Kernel.-(1)

      assert name_count >= 3,
        "Expected name 'process_data' at least 3 times, found #{name_count}"
    end

    test "includes parameters and calls" do
      chunk = hd(Chunker.chunk_entity(@sample_entity))
      text = Chunker.prepare_for_keywords(chunk)

      assert String.contains?(text, "input")
      assert String.contains?(text, "transform")
    end

    test "includes content" do
      chunk = hd(Chunker.chunk_entity(@sample_entity))
      text = Chunker.prepare_for_keywords(chunk)

      assert String.contains?(text, "def process_data")
    end
  end

  describe "chunk_entity/1" do
    test "produces chunk with all required fields" do
      [chunk] = Chunker.chunk_entity(@sample_entity)

      assert chunk.id != nil
      assert chunk.name == "process_data"
      assert chunk.entity_type == :function
      assert chunk.file_path == "lib/test.ex"
      assert chunk.start_line == 10
      assert chunk.parameters == ["input"]
      assert chunk.calls == ["transform"]
    end

    test "generates deterministic IDs" do
      [chunk1] = Chunker.chunk_entity(@sample_entity)
      [chunk2] = Chunker.chunk_entity(@sample_entity)
      assert chunk1.id == chunk2.id
    end
  end

  describe "chunk_entities/1" do
    test "processes list of entities" do
      entity2 = %{@sample_entity | name: "validate", start_line: 20}
      chunks = Chunker.chunk_entities([@sample_entity, entity2])

      assert length(chunks) == 2
      names = Enum.map(chunks, & &1.name)
      assert "process_data" in names
      assert "validate" in names
    end
  end
end
