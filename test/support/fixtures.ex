defmodule ElixirNexus.TestFixtures do
  @moduledoc "Shared factory functions for test data."

  def code_schema_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        file_path: "lib/example.ex",
        entity_type: :function,
        name: "my_function",
        content: "def my_function(a, b), do: a + b",
        start_line: 1,
        end_line: 1,
        docstring: nil,
        module_path: "Example",
        parameters: ["a", "b"],
        visibility: :public,
        calls: ["other_func"],
        is_a: [],
        contains: [],
        language: :elixir
      },
      overrides
    )
  end

  def build_code_schema(overrides \\ %{}) do
    struct(ElixirNexus.CodeSchema, code_schema_attrs(overrides))
  end

  def build_chunk(overrides \\ %{}) do
    defaults = %{
      id: "chunk_#{System.unique_integer([:positive])}",
      entity_type: :function,
      name: "test_func",
      file_path: "lib/test.ex",
      content: "def test_func, do: :ok",
      start_line: 1,
      end_line: 1,
      parameters: [],
      visibility: :public,
      calls: [],
      is_a: [],
      contains: [],
      language: :elixir
    }

    Map.merge(defaults, overrides)
  end

  def build_search_result(overrides \\ %{}) do
    defaults = %{
      id: System.unique_integer([:positive]),
      score: 0.85,
      entity: %{
        "name" => "test_func",
        "file_path" => "lib/test.ex",
        "entity_type" => "function",
        "start_line" => 1,
        "end_line" => 10,
        "content" => "def test_func, do: :ok",
        "visibility" => "public",
        "parameters" => [],
        "calls" => [],
        "is_a" => [],
        "contains" => [],
        "language" => "elixir"
      }
    }

    Map.merge(defaults, overrides)
  end

  def build_qdrant_point(overrides \\ %{}) do
    defaults = %{
      "id" => System.unique_integer([:positive]),
      "score" => 0.9,
      "payload" => %{
        "name" => "test_func",
        "file_path" => "lib/test.ex",
        "entity_type" => "function",
        "start_line" => 1,
        "end_line" => 10,
        "content" => "def test_func, do: :ok",
        "visibility" => "public",
        "parameters" => [],
        "calls" => ["helper"],
        "is_a" => [],
        "contains" => [],
        "language" => "elixir"
      }
    }

    Map.merge(defaults, overrides)
  end

  def build_graph_node(overrides \\ %{}) do
    defaults = %{
      "name" => "test_func",
      "type" => "function",
      "calls" => [],
      "is_a" => [],
      "contains" => [],
      "incoming_count" => 0
    }

    Map.merge(defaults, overrides)
  end

  def sample_js_ast do
    %{
      "kind" => "program",
      "children" => [
        %{
          "kind" => "function_declaration",
          "name" => "fetchData",
          "start_row" => 0,
          "end_row" => 5,
          "children" => [
            %{
              "kind" => "formal_parameters",
              "children" => [
                %{"kind" => "identifier", "name" => "url", "text" => "url"}
              ]
            },
            %{
              "kind" => "statement_block",
              "children" => [
                %{
                  "kind" => "call_expression",
                  "name" => "fetch",
                  "children" => []
                }
              ]
            }
          ]
        }
      ]
    }
  end

  def sample_go_ast do
    %{
      "kind" => "source_file",
      "children" => [
        %{
          "kind" => "function_declaration",
          "name" => "main",
          "start_row" => 0,
          "end_row" => 3,
          "children" => [
            %{
              "kind" => "parameter_list",
              "children" => []
            }
          ]
        },
        %{
          "kind" => "import_declaration",
          "children" => [
            %{"kind" => "interpreted_string_literal", "text" => "\"fmt\""}
          ]
        }
      ]
    }
  end
end
