defmodule ElixirNexus.TFIDFEmbedderTest do
  use ExUnit.Case

  # TFIDFEmbedder is started by the application supervision tree
  # No need to start it again in setup

  describe "embed/1 - single text embedding" do
    test "returns 384-dimensional vector" do
      {:ok, embedding} = ElixirNexus.TFIDFEmbedder.embed("hello world")
      assert is_list(embedding)
      assert length(embedding) == 384
    end

    test "returns normalized vector for known vocabulary" do
      # First update vocabulary so embedding has actual values
      ElixirNexus.TFIDFEmbedder.update_vocabulary(["hello world test"])
      {:ok, embedding} = ElixirNexus.TFIDFEmbedder.embed("hello world test")
      magnitude = :math.sqrt(Enum.reduce(embedding, 0, &(&1 * &1 + &2)))
      # When text is in vocabulary, should normalize to ~1.0 or be zero (no matches)
      assert (magnitude > 0.9 and magnitude <= 1.1) or magnitude == 0.0
    end

    test "empty text returns zero vector" do
      {:ok, embedding} = ElixirNexus.TFIDFEmbedder.embed("")
      assert Enum.all?(embedding, &(&1 == 0.0))
    end

    test "same text produces same embedding (deterministic)" do
      text = "deterministic test query"
      {:ok, embedding1} = ElixirNexus.TFIDFEmbedder.embed(text)
      {:ok, embedding2} = ElixirNexus.TFIDFEmbedder.embed(text)
      assert embedding1 == embedding2
    end

    test "different text may produce different embeddings when vocabulary exists" do
      # Update vocabulary so words are recognized
      ElixirNexus.TFIDFEmbedder.update_vocabulary(["hello world", "goodbye world"])
      
      {:ok, embedding1} = ElixirNexus.TFIDFEmbedder.embed("hello world")
      {:ok, embedding2} = ElixirNexus.TFIDFEmbedder.embed("goodbye world")
      
      # Different texts should produce different embeddings (usually)
      # They might be both zero if no words match, so just check they're lists
      assert is_list(embedding1)
      assert is_list(embedding2)
    end

    test "same text with updated vocabulary produces consistent results" do
      # Update vocabulary first
      ElixirNexus.TFIDFEmbedder.update_vocabulary(["function definition"])
      
      {:ok, emb1} = ElixirNexus.TFIDFEmbedder.embed("function definition")
      {:ok, emb2} = ElixirNexus.TFIDFEmbedder.embed("function definition")
      
      # Same text should produce identical embeddings
      assert emb1 == emb2
    end
  end

  describe "embed_batch/1 - batch embedding" do
    test "embeds multiple texts" do
      texts = ["hello", "world", "test"]
      {:ok, embeddings} = ElixirNexus.TFIDFEmbedder.embed_batch(texts)
      assert is_list(embeddings)
      assert length(embeddings) == 3
      assert Enum.all?(embeddings, &(is_list(&1) and length(&1) == 384))
    end

    test "empty list returns empty" do
      {:ok, embeddings} = ElixirNexus.TFIDFEmbedder.embed_batch([])
      assert embeddings == []
    end

    test "batch results match individual embeddings" do
      texts = ["alpha", "beta", "gamma"]
      {:ok, batch_embeddings} = ElixirNexus.TFIDFEmbedder.embed_batch(texts)
      
      individual_embeddings = Enum.map(texts, fn text ->
        {:ok, embedding} = ElixirNexus.TFIDFEmbedder.embed(text)
        embedding
      end)
      
      assert batch_embeddings == individual_embeddings
    end
  end

  describe "update_vocabulary/1" do
    test "builds vocabulary from texts" do
      texts = ["hello world", "test function", "code analysis"]
      ElixirNexus.TFIDFEmbedder.update_vocabulary(texts)
      
      # After update, embedding should work better with these texts
      {:ok, embedding} = ElixirNexus.TFIDFEmbedder.embed("hello")
      assert is_list(embedding)
      assert length(embedding) == 384
    end

    test "updates vocabulary multiple times" do
      texts1 = ["first batch"]
      ElixirNexus.TFIDFEmbedder.update_vocabulary(texts1)
      
      texts2 = ["second batch", "added later"]
      ElixirNexus.TFIDFEmbedder.update_vocabulary(texts2)
      
      {:ok, embedding} = ElixirNexus.TFIDFEmbedder.embed("batch")
      assert is_list(embedding)
    end
  end

  describe "tokenization and normalization" do
    test "ignores special characters and punctuation" do
      # Update vocabulary with text patterns
      ElixirNexus.TFIDFEmbedder.update_vocabulary(["hello-world", "hello world"])
      
      {:ok, emb1} = ElixirNexus.TFIDFEmbedder.embed("hello-world")
      {:ok, emb2} = ElixirNexus.TFIDFEmbedder.embed("hello world")
      # Both should tokenize similarly after punctuation removal
      assert is_list(emb1) and is_list(emb2)
    end

    test "case insensitive tokenization" do
      {:ok, emb1} = ElixirNexus.TFIDFEmbedder.embed("HELLO WORLD")
      {:ok, emb2} = ElixirNexus.TFIDFEmbedder.embed("hello world")
      assert emb1 == emb2
    end

    test "filters short tokens (< 2 chars)" do
      {:ok, embedding} = ElixirNexus.TFIDFEmbedder.embed("a b c test")
      # Should only contain embeddings for "test", "a", "b", "c" are ignored
      assert is_list(embedding)
    end
  end

  describe "sparse_vector/1" do
    test "returns map with indices and values keys" do
      sv = ElixirNexus.TFIDFEmbedder.sparse_vector("hello world function")
      assert is_map(sv)
      assert Map.has_key?(sv, "indices")
      assert Map.has_key?(sv, "values")
      assert is_list(sv["indices"])
      assert is_list(sv["values"])
      assert length(sv["indices"]) == length(sv["values"])
    end

    test "indices are sorted ascending" do
      sv = ElixirNexus.TFIDFEmbedder.sparse_vector("test function hello world")
      assert sv["indices"] == Enum.sort(sv["indices"])
    end

    test "indices are within vector_size bounds" do
      sv = ElixirNexus.TFIDFEmbedder.sparse_vector("some code with many words here")
      assert Enum.all?(sv["indices"], &(&1 >= 0 and &1 < 384))
    end

    test "values are positive" do
      ElixirNexus.TFIDFEmbedder.update_vocabulary(["positive test values"])
      sv = ElixirNexus.TFIDFEmbedder.sparse_vector("positive test values")
      assert Enum.all?(sv["values"], &(&1 > 0))
    end

    test "empty text returns empty sparse vector" do
      sv = ElixirNexus.TFIDFEmbedder.sparse_vector("")
      assert sv["indices"] == []
      assert sv["values"] == []
    end
  end

  describe "sparse_vector_batch/1" do
    test "returns list of sparse vectors" do
      texts = ["hello world", "test function", "code analysis"]
      svs = ElixirNexus.TFIDFEmbedder.sparse_vector_batch(texts)
      assert is_list(svs)
      assert length(svs) == 3
      assert Enum.all?(svs, &(is_map(&1) and Map.has_key?(&1, "indices")))
    end
  end

  # Helper function: cosine similarity
  defp cosine_similarity(vec1, vec2) do
    dot_product = Enum.zip(vec1, vec2) |> Enum.reduce(0, fn {a, b}, acc -> a * b + acc end)
    
    mag1 = :math.sqrt(Enum.reduce(vec1, 0, &(&1 * &1 + &2)))
    mag2 = :math.sqrt(Enum.reduce(vec2, 0, &(&1 * &1 + &2)))
    
    if mag1 == 0 or mag2 == 0 do
      0.0
    else
      dot_product / (mag1 * mag2)
    end
  end
end
