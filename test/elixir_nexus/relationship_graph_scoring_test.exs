defmodule ElixirNexus.RelationshipGraphScoringTest do
  use ExUnit.Case

  alias ElixirNexus.RelationshipGraph

  describe "score_by_relationships/3" do
    test "scores results by closeness to seed entities" do
      seed_ids = ["seed1"]

      results = [
        %{"id" => "seed1", "entity" => %{"name" => "target"}},
        %{"id" => "related", "entity" => %{"name" => "helper"}},
        %{"id" => "unrelated", "entity" => %{"name" => "other"}}
      ]

      graph = %{
        "seed1" => %{
          "name" => "target",
          "calls" => ["helper"],
          "is_a" => [],
          "contains" => [],
          "incoming_count" => 0
        },
        "related" => %{
          "name" => "helper",
          "calls" => [],
          "is_a" => [],
          "contains" => [],
          "incoming_count" => 1
        },
        "unrelated" => %{
          "name" => "other",
          "calls" => [],
          "is_a" => [],
          "contains" => [],
          "incoming_count" => 0
        }
      }

      scored = RelationshipGraph.score_by_relationships(results, seed_ids, graph)

      seed_result = Enum.find(scored, &(&1["id"] == "seed1"))
      assert seed_result["relationship_score"] == 100.0

      related_score = Enum.find(scored, &(&1["id"] == "related"))["relationship_score"]
      unrelated_score = Enum.find(scored, &(&1["id"] == "unrelated"))["relationship_score"]
      assert related_score >= unrelated_score
    end
  end

  describe "rerank_with_graph/3" do
    test "combines vector similarity with relationship scores" do
      results = [
        %{"id" => "r1", "score" => 0.9, "entity" => %{"name" => "primary"}},
        %{"id" => "r2", "score" => 0.8, "entity" => %{"name" => "secondary"}}
      ]

      graph = %{
        "r1" => %{
          "name" => "primary",
          "calls" => ["secondary"],
          "is_a" => [],
          "contains" => [],
          "incoming_count" => 5
        },
        "r2" => %{
          "name" => "secondary",
          "calls" => [],
          "is_a" => [],
          "contains" => [],
          "incoming_count" => 0
        }
      }

      reranked = RelationshipGraph.rerank_with_graph(results, graph, 0.3)

      assert is_list(reranked)
      assert length(reranked) == 2
      assert Enum.all?(reranked, &Map.has_key?(&1, "combined_score"))
      assert Enum.all?(reranked, &Map.has_key?(&1, "vector_score"))
    end

    test "reranks by combined score in descending order" do
      results = [
        %{"id" => "a", "score" => 0.5, "entity" => %{"name" => "a"}},
        %{"id" => "b", "score" => 0.9, "entity" => %{"name" => "b"}}
      ]

      graph = %{
        "a" => %{"name" => "a", "calls" => [], "is_a" => [], "contains" => [], "incoming_count" => 10},
        "b" => %{"name" => "b", "calls" => [], "is_a" => [], "contains" => [], "incoming_count" => 0}
      }

      reranked = RelationshipGraph.rerank_with_graph(results, graph, 0.3)

      assert length(reranked) == 2
      assert Enum.all?(reranked, &is_number(&1["combined_score"]))
    end
  end

  describe "explain_ranking/2" do
    test "explains ranking for a result" do
      result = %{
        "id" => "f1",
        "score" => 0.85,
        "combined_score" => 0.88,
        "relationship_score" => 5.0,
        "entity" => %{
          "name" => "process",
          "entity_type" => "function",
          "calls" => ["helper"],
          "is_a" => [],
          "contains" => []
        }
      }

      graph = %{
        "f1" => %{"name" => "process", "outgoing_degree" => 1, "incoming_count" => 3}
      }

      explanation = RelationshipGraph.explain_ranking(result, graph)

      assert explanation["name"] == "process"
      assert explanation["type"] == "function"
      assert explanation["vector_score"] == 0.85
      assert explanation["combined_score"] == 0.88
      assert explanation["relationship_score"] == 5.0
    end
  end
end
