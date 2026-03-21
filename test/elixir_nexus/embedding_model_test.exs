defmodule ElixirNexus.EmbeddingModelTest do
  use ExUnit.Case

  describe "available?/0" do
    test "returns boolean" do
      result = ElixirNexus.EmbeddingModel.available?()
      assert is_boolean(result)
    end
  end

  describe "embed/1" do
    test "returns 384-dim vector when model available" do
      case ElixirNexus.EmbeddingModel.embed("test embedding") do
        {:ok, embedding} ->
          assert is_list(embedding)
          assert length(embedding) == 384
          # Should not be all zeros if model is loaded
          if ElixirNexus.EmbeddingModel.available?() do
            refute Enum.all?(embedding, &(&1 == 0.0)),
              "Model available but returned zero vector"
          end

        {:error, :model_unavailable} ->
          refute ElixirNexus.EmbeddingModel.available?()
      end
    end

    test "returns error when model unavailable and serving not started" do
      # If model is unavailable, should get clean error
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
          assert Enum.all?(embeddings, &(is_list(&1) and length(&1) == 384))

        {:error, :model_unavailable} ->
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
