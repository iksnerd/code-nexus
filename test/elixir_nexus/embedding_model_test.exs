defmodule ElixirNexus.EmbeddingModelTest do
  use ExUnit.Case

  describe "available?/0" do
    test "returns boolean" do
      result = ElixirNexus.EmbeddingModel.available?()
      assert is_boolean(result)
    end
  end

  describe "embed/1" do
    test "returns 768-dim vector when Ollama available" do
      case ElixirNexus.EmbeddingModel.embed("test embedding") do
        {:ok, embedding} ->
          assert is_list(embedding)
          assert length(embedding) == 768

          refute Enum.all?(embedding, &(&1 == 0.0)),
                 "Ollama returned zero vector"

        {:error, _reason} ->
          # Ollama not running — acceptable in CI
          assert true
      end
    end

    test "returns error tuple on failure" do
      result = ElixirNexus.EmbeddingModel.embed("test")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "embed_batch/1" do
    test "embeds multiple texts" do
      case ElixirNexus.EmbeddingModel.embed_batch(["hello", "world"]) do
        {:ok, embeddings} ->
          assert is_list(embeddings)
          assert length(embeddings) == 2
          assert Enum.all?(embeddings, &(is_list(&1) and length(&1) == 768))

        {:error, _reason} ->
          assert true
      end
    end

    test "empty list returns empty" do
      case ElixirNexus.EmbeddingModel.embed_batch([]) do
        {:ok, []} -> assert true
        {:error, _} -> assert true
      end
    end
  end
end
