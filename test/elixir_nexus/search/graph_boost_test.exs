defmodule ElixirNexus.Search.GraphBoostTest do
  use ExUnit.Case, async: true

  alias ElixirNexus.Search.GraphBoost

  defp make_result(id, name, score) do
    %{
      id: id,
      score: score,
      entity: %{"name" => name, "entity_type" => "function"}
    }
  end

  describe "apply_graph_boost/2" do
    test "seed results (top 5) get +0.1 boost" do
      results = [
        make_result("1", "alpha", 0.9),
        make_result("2", "beta", 0.8),
        make_result("3", "gamma", 0.7),
        make_result("4", "delta", 0.6),
        make_result("5", "epsilon", 0.5),
        make_result("6", "zeta", 0.4)
      ]

      graph = %{}

      boosted = GraphBoost.apply_graph_boost(results, graph)

      # Top 5 by score get seed boost of 0.1
      top5 = boosted |> Enum.sort_by(& &1.id) |> Enum.take(5)

      for result <- top5 do
        original = Enum.find(results, &(&1.id == result.id))
        assert_in_delta result.score, original.score + 0.1, 0.001
      end

      # 6th result is not in seed set, gets 0.0 with empty graph
      sixth = Enum.find(boosted, &(&1.id == "6"))
      assert_in_delta sixth.score, 0.4, 0.001
    end

    test "nodes with incoming references get incoming boost" do
      results = [
        make_result("1", "main", 0.9),
        make_result("2", "helper", 0.3)
      ]

      # helper has 3 incoming references
      graph = %{
        "helper" => %{"name" => "helper", "incoming_count" => 3, "calls" => []}
      }

      boosted = GraphBoost.apply_graph_boost(results, graph)

      # Both are in top 5 (seed) so they get the seed boost of 0.1
      helper = Enum.find(boosted, &(&1.id == "2"))
      assert_in_delta helper.score, 0.3 + 0.1, 0.001
    end

    test "nodes with incoming_count > 0 that are NOT in seed set get incoming boost" do
      # Create 6 results so the 6th is outside the seed set
      results = [
        make_result("1", "a", 0.9),
        make_result("2", "b", 0.8),
        make_result("3", "c", 0.7),
        make_result("4", "d", 0.6),
        make_result("5", "e", 0.5),
        make_result("6", "target", 0.2)
      ]

      graph = %{
        "target" => %{"name" => "target", "incoming_count" => 4, "calls" => []}
      }

      boosted = GraphBoost.apply_graph_boost(results, graph)

      target = Enum.find(boosted, &(&1.id == "6"))
      # incoming boost: min(4 * 0.02, 0.1) = 0.08
      assert_in_delta target.score, 0.2 + 0.08, 0.001
    end

    test "incoming boost is capped at 0.1" do
      results = [
        make_result("1", "a", 0.9),
        make_result("2", "b", 0.8),
        make_result("3", "c", 0.7),
        make_result("4", "d", 0.6),
        make_result("5", "e", 0.5),
        make_result("6", "popular", 0.2)
      ]

      graph = %{
        "popular" => %{"name" => "popular", "incoming_count" => 100, "calls" => []}
      }

      boosted = GraphBoost.apply_graph_boost(results, graph)

      popular = Enum.find(boosted, &(&1.id == "6"))
      # capped: min(100 * 0.02, 0.1) = 0.1
      assert_in_delta popular.score, 0.2 + 0.1, 0.001
    end

    test "non-seed node calling seed functions gets related boost" do
      results = [
        make_result("1", "core_func", 0.9),
        make_result("2", "b", 0.8),
        make_result("3", "c", 0.7),
        make_result("4", "d", 0.6),
        make_result("5", "e", 0.5),
        make_result("6", "caller", 0.2)
      ]

      graph = %{
        "core_func" => %{"name" => "core_func", "incoming_count" => 0, "calls" => []},
        "caller" => %{"name" => "caller", "incoming_count" => 0, "calls" => ["core_func"]}
      }

      boosted = GraphBoost.apply_graph_boost(results, graph)

      caller = Enum.find(boosted, &(&1.id == "6"))
      # related boost: min(1 * 0.03, 0.1) = 0.03
      assert_in_delta caller.score, 0.2 + 0.03, 0.001
    end

    test "empty graph still applies seed boost" do
      results = [make_result("1", "func", 0.5)]
      boosted = GraphBoost.apply_graph_boost(results, %{})

      assert_in_delta hd(boosted).score, 0.5 + 0.1, 0.001
    end

    test "empty results returns empty list" do
      assert GraphBoost.apply_graph_boost([], %{}) == []
    end
  end

  describe "get_entity_id/1" do
    test "returns entity name when present" do
      result = %{id: "abc123", entity: %{"name" => "my_function"}}
      assert GraphBoost.get_entity_id(result) == "my_function"
    end

    test "falls back to id when entity is nil" do
      result = %{id: "fallback_id", entity: nil}
      assert GraphBoost.get_entity_id(result) == "fallback_id"
    end

    test "falls back to id when entity has no name" do
      result = %{id: "fallback_id", entity: %{}}
      assert GraphBoost.get_entity_id(result) == "fallback_id"
    end
  end
end
