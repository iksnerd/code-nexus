defmodule ElixirNexus.Search.ScoringTest do
  use ExUnit.Case, async: true

  alias ElixirNexus.Search.Scoring

  defp make_result(name, type, score) do
    %{
      id: "#{name}_#{type}_#{score}",
      score: score,
      entity: %{"name" => name, "entity_type" => type}
    }
  end

  describe "deduplicate/1" do
    test "keeps highest score when duplicates exist" do
      results = [
        make_result("fetch", "function", 0.9),
        make_result("fetch", "function", 0.7),
        make_result("fetch", "function", 0.5)
      ]

      deduped = Scoring.deduplicate(results)

      assert length(deduped) == 1
      assert hd(deduped).score == 0.9
    end

    test "keeps separate entries for different entity types" do
      results = [
        make_result("User", "class", 0.8),
        make_result("User", "function", 0.6)
      ]

      deduped = Scoring.deduplicate(results)

      assert length(deduped) == 2
    end

    test "keeps separate entries for different names" do
      results = [
        make_result("alpha", "function", 0.9),
        make_result("beta", "function", 0.8)
      ]

      deduped = Scoring.deduplicate(results)

      assert length(deduped) == 2
    end

    test "passes through results with no duplicates" do
      results = [
        make_result("foo", "function", 0.9),
        make_result("bar", "class", 0.8),
        make_result("baz", "module", 0.7)
      ]

      deduped = Scoring.deduplicate(results)

      assert length(deduped) == 3
    end

    test "handles empty list" do
      assert Scoring.deduplicate([]) == []
    end

    test "handles single item" do
      results = [make_result("only", "function", 0.5)]
      deduped = Scoring.deduplicate(results)

      assert length(deduped) == 1
      assert hd(deduped).score == 0.5
    end

    test "deduplicates multiple groups" do
      results = [
        make_result("fetch", "function", 0.9),
        make_result("fetch", "function", 0.3),
        make_result("save", "function", 0.8),
        make_result("save", "function", 0.2)
      ]

      deduped = Scoring.deduplicate(results)

      assert length(deduped) == 2
      scores = Enum.map(deduped, & &1.score) |> Enum.sort(:desc)
      assert scores == [0.9, 0.8]
    end
  end
end
