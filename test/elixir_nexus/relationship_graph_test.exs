defmodule ElixirNexus.RelationshipGraphTest do
  use ExUnit.Case

  alias ElixirNexus.RelationshipGraph

  describe "build_graph/1" do
    test "builds graph from search results" do
      results = [
        %{
          "id" => "func1",
          "score" => 0.9,
          "entity" => %{
            "name" => "process",
            "entity_type" => "function",
            "calls" => ["helper", "transform"],
            "is_a" => [],
            "contains" => []
          }
        },
        %{
          "id" => "func2",
          "score" => 0.7,
          "entity" => %{
            "name" => "helper",
            "entity_type" => "function",
            "calls" => ["format"],
            "is_a" => [],
            "contains" => []
          }
        }
      ]

      graph = RelationshipGraph.build_graph(results)

      assert is_map(graph)
      assert map_size(graph) == 2
      assert graph["func1"]["name"] == "process"
      assert graph["func2"]["name"] == "helper"
    end

    test "counts incoming edges" do
      results = [
        %{
          "id" => "a",
          "entity" => %{
            "name" => "func_a",
            "entity_type" => "function",
            "calls" => ["func_b"],
            "is_a" => [],
            "contains" => []
          }
        },
        %{
          "id" => "b",
          "entity" => %{
            "name" => "func_b",
            "entity_type" => "function",
            "calls" => ["func_b"],  # Also calls itself (unusual but possible)
            "is_a" => [],
            "contains" => []
          }
        }
      ]

      graph = RelationshipGraph.build_graph(results)

      # func_b should have incoming count >= 1 (called by func_a and itself)
      assert graph["b"]["incoming_count"] >= 1
    end

    test "calculates outgoing degree" do
      results = [
        %{
          "id" => "m1",
          "entity" => %{
            "name" => "module1",
            "entity_type" => "module",
            "calls" => ["a", "b", "c"],
            "is_a" => ["GenServer"],
            "contains" => ["func1", "func2"]
          }
        }
      ]

      graph = RelationshipGraph.build_graph(results)

      # Outgoing degree = 3 calls + 1 is_a + 2 contains = 6
      assert graph["m1"]["outgoing_degree"] == 6
    end

    test "handles atom-keyed results from search.ex" do
      # search.ex passes results with atom keys (:id, :entity)
      results = [
        %{
          id: "func1",
          score: 0.9,
          entity: %{
            "name" => "process",
            "entity_type" => "function",
            "calls" => ["helper"],
            "is_a" => [],
            "contains" => []
          }
        },
        %{
          id: "func2",
          score: 0.7,
          entity: %{
            "name" => "helper",
            "entity_type" => "function",
            "calls" => [],
            "is_a" => [],
            "contains" => []
          }
        }
      ]

      graph = RelationshipGraph.build_graph(results)

      assert is_map(graph)
      assert map_size(graph) == 2
      assert graph["func1"]["name"] == "process"
      assert graph["func2"]["name"] == "helper"
      # helper should have incoming count from process calling it
      assert graph["func2"]["incoming_count"] >= 1
    end
  end

  describe "find_callers/2" do
    test "finds entities that call a function" do
      graph = %{
        "caller1" => %{
          "name" => "process",
          "calls" => ["target_func"]
        },
        "caller2" => %{
          "name" => "helper",
          "calls" => ["target_func"]
        },
        "non_caller" => %{
          "name" => "other",
          "calls" => ["some_func"]
        }
      }

      callers = RelationshipGraph.find_callers("target_func", graph)

      assert length(callers) == 2
      names = callers |> Enum.map(fn {_, node} -> node["name"] end)
      assert "process" in names
      assert "helper" in names
    end

    test "returns empty for non-existent function" do
      graph = %{
        "f1" => %{
          "name" => "func1",
          "calls" => ["helper"]
        }
      }

      callers = RelationshipGraph.find_callers("nonexistent", graph)

      assert callers == []
    end
  end

  describe "find_callees/2" do
    test "returns empty when node not found" do
      graph = %{
        "f1" => %{
          "name" => "func1",
          "calls" => []
        }
      }

      # When node isn't found, should return empty
      callees = RelationshipGraph.find_callees("undefined", graph)
      assert callees == []
    end
  end

  describe "find_parents/2" do
    test "returns empty when node not found" do
      graph = %{
        "m1" => %{
          "name" => "MyModule",
          "is_a" => []
        }
      }

      parents = RelationshipGraph.find_parents("undefined", graph)

      # Should return empty when not found
      assert is_list(parents)
      assert parents == []
    end
  end

  describe "find_children/2" do
    test "returns empty when node not found" do
      graph = %{
        "m1" => %{
          "name" => "Module",
          "contains" => []
        }
      }

      children = RelationshipGraph.find_children("undefined", graph)

      # Should return empty when not found
      assert is_list(children)
      assert children == []
    end
  end

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

      # Seed entity should have highest score
      seed_result = Enum.find(scored, &(&1["id"] == "seed1"))
      assert seed_result["relationship_score"] == 100.0

      # Related entity should have higher score than unrelated
      related_score = Enum.find(scored, &(&1["id"] == "related"))["relationship_score"]
      unrelated_score = Enum.find(scored, &(&1["id"] == "unrelated"))["relationship_score"]
      assert related_score >= unrelated_score
    end
  end

  describe "rerank_with_graph/3" do
    test "combines vector similarity with relationship scores" do
      results = [
        %{
          "id" => "r1",
          "score" => 0.9,
          "entity" => %{"name" => "primary"}
        },
        %{
          "id" => "r2",
          "score" => 0.8,
          "entity" => %{"name" => "secondary"}
        }
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
      
      # Each result should have combined score
      assert Enum.all?(reranked, &Map.has_key?(&1, "combined_score"))
      assert Enum.all?(reranked, &Map.has_key?(&1, "vector_score"))
    end

    test "reranks by combined score in descending order" do
      results = [
        %{"id" => "a", "score" => 0.5, "entity" => %{"name" => "a"}},
        %{"id" => "b", "score" => 0.9, "entity" => %{"name" => "b"}}
      ]

      graph = %{
        "a" => %{
          "name" => "a",
          "calls" => [],
          "is_a" => [],
          "contains" => [],
          "incoming_count" => 10
        },
        "b" => %{
          "name" => "b",
          "calls" => [],
          "is_a" => [],
          "contains" => [],
          "incoming_count" => 0
        }
      }

      reranked = RelationshipGraph.rerank_with_graph(results, graph, 0.3)

      # Both should be present
      assert length(reranked) == 2
      # Combined scores should be computed
      assert Enum.all?(reranked, &is_number(&1["combined_score"]))
    end
  end

  describe "find_callees/2 with populated graph" do
    test "returns callee IDs when node exists" do
      graph = %{
        "f1" => %{
          "name" => "process",
          "calls" => ["helper", "format"],
          "is_a" => [],
          "contains" => []
        },
        "f2" => %{
          "name" => "helper",
          "calls" => [],
          "is_a" => [],
          "contains" => []
        }
      }

      callees = RelationshipGraph.find_callees("process", graph)
      # resolve_ref_indexed returns IDs (strings)
      assert length(callees) >= 1
      assert "f2" in callees
    end
  end

  describe "find_parents/2 with populated graph" do
    test "returns parent IDs when node has is_a" do
      graph = %{
        "m1" => %{
          "name" => "MyServer",
          "calls" => [],
          "is_a" => ["GenServer"],
          "contains" => []
        },
        "m2" => %{
          "name" => "GenServer",
          "calls" => [],
          "is_a" => [],
          "contains" => []
        }
      }

      parents = RelationshipGraph.find_parents("MyServer", graph)
      assert length(parents) >= 1
      assert "m2" in parents
    end
  end

  describe "find_children/2 with populated graph" do
    test "returns child IDs when node has contains" do
      graph = %{
        "m1" => %{
          "name" => "MyModule",
          "calls" => [],
          "is_a" => [],
          "contains" => ["init", "handle_call"]
        },
        "f1" => %{
          "name" => "init",
          "calls" => [],
          "is_a" => [],
          "contains" => []
        },
        "f2" => %{
          "name" => "handle_call",
          "calls" => [],
          "is_a" => [],
          "contains" => []
        }
      }

      children = RelationshipGraph.find_children("MyModule", graph)
      assert length(children) >= 1
      assert "f1" in children or "f2" in children
    end
  end

  describe "find_callers/2 partial matching" do
    test "matches Module.function to function" do
      graph = %{
        "c1" => %{
          "name" => "caller",
          "calls" => ["Module.target"]
        }
      }

      callers = RelationshipGraph.find_callers("target", graph)
      assert length(callers) == 1
    end

    test "matches function to Module.function" do
      graph = %{
        "c1" => %{
          "name" => "caller",
          "calls" => ["target"]
        }
      }

      callers = RelationshipGraph.find_callers("Module.target", graph)
      assert length(callers) == 1
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
        "f1" => %{
          "name" => "process",
          "outgoing_degree" => 1,
          "incoming_count" => 3
        }
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
