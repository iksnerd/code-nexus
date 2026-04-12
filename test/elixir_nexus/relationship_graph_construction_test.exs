defmodule ElixirNexus.RelationshipGraphConstructionTest do
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
            "calls" => ["func_b"],
            "is_a" => [],
            "contains" => []
          }
        }
      ]

      graph = RelationshipGraph.build_graph(results)

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

      # outgoing_degree = 3 calls + 1 is_a + 2 contains = 6
      assert graph["m1"]["outgoing_degree"] == 6
    end

    test "handles atom-keyed results from search.ex" do
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
      assert graph["func2"]["incoming_count"] >= 1
    end
  end
end
