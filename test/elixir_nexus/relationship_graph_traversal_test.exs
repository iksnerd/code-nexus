defmodule ElixirNexus.RelationshipGraphTraversalTest do
  use ExUnit.Case

  alias ElixirNexus.RelationshipGraph

  describe "find_callers/2" do
    test "finds entities that call a function" do
      graph = %{
        "caller1" => %{"name" => "process", "calls" => ["target_func"]},
        "caller2" => %{"name" => "helper", "calls" => ["target_func"]},
        "non_caller" => %{"name" => "other", "calls" => ["some_func"]}
      }

      callers = RelationshipGraph.find_callers("target_func", graph)

      assert length(callers) == 2
      names = callers |> Enum.map(fn {_, node} -> node["name"] end)
      assert "process" in names
      assert "helper" in names
    end

    test "returns empty for non-existent function" do
      graph = %{"f1" => %{"name" => "func1", "calls" => ["helper"]}}

      callers = RelationshipGraph.find_callers("nonexistent", graph)

      assert callers == []
    end

    test "matches Module.function to function" do
      graph = %{"c1" => %{"name" => "caller", "calls" => ["Module.target"]}}

      callers = RelationshipGraph.find_callers("target", graph)
      assert length(callers) == 1
    end

    test "matches function to Module.function" do
      graph = %{"c1" => %{"name" => "caller", "calls" => ["target"]}}

      callers = RelationshipGraph.find_callers("Module.target", graph)
      assert length(callers) == 1
    end
  end

  describe "find_callees/2" do
    test "returns empty when node not found" do
      graph = %{"f1" => %{"name" => "func1", "calls" => []}}

      callees = RelationshipGraph.find_callees("undefined", graph)
      assert callees == []
    end

    test "returns callee IDs when node exists" do
      graph = %{
        "f1" => %{
          "name" => "process",
          "calls" => ["helper", "format"],
          "is_a" => [],
          "contains" => []
        },
        "f2" => %{"name" => "helper", "calls" => [], "is_a" => [], "contains" => []}
      }

      callees = RelationshipGraph.find_callees("process", graph)
      assert length(callees) >= 1
      assert "f2" in callees
    end
  end

  describe "find_parents/2" do
    test "returns empty when node not found" do
      graph = %{"m1" => %{"name" => "MyModule", "is_a" => []}}

      parents = RelationshipGraph.find_parents("undefined", graph)

      assert is_list(parents)
      assert parents == []
    end

    test "returns parent IDs when node has is_a" do
      graph = %{
        "m1" => %{"name" => "MyServer", "calls" => [], "is_a" => ["GenServer"], "contains" => []},
        "m2" => %{"name" => "GenServer", "calls" => [], "is_a" => [], "contains" => []}
      }

      parents = RelationshipGraph.find_parents("MyServer", graph)
      assert length(parents) >= 1
      assert "m2" in parents
    end
  end

  describe "find_children/2" do
    test "returns empty when node not found" do
      graph = %{"m1" => %{"name" => "Module", "contains" => []}}

      children = RelationshipGraph.find_children("undefined", graph)

      assert is_list(children)
      assert children == []
    end

    test "returns child IDs when node has contains" do
      graph = %{
        "m1" => %{
          "name" => "MyModule",
          "calls" => [],
          "is_a" => [],
          "contains" => ["init", "handle_call"]
        },
        "f1" => %{"name" => "init", "calls" => [], "is_a" => [], "contains" => []},
        "f2" => %{"name" => "handle_call", "calls" => [], "is_a" => [], "contains" => []}
      }

      children = RelationshipGraph.find_children("MyModule", graph)
      assert length(children) >= 1
      assert "f1" in children or "f2" in children
    end
  end
end
