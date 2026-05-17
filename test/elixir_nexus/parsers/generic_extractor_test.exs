defmodule ElixirNexus.Parsers.GenericExtractorTest do
  use ExUnit.Case, async: true

  alias ElixirNexus.Parsers.GenericExtractor

  describe "extract_entities/3 - Go function" do
    test "extracts a Go function declaration" do
      ast = %{
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
                "children" => [
                  %{"kind" => "identifier", "name" => "args", "text" => "args"}
                ]
              }
            ]
          }
        ]
      }

      source = "func main(args []string) {\n  fmt.Println(args)\n}\n"
      entities = GenericExtractor.extract_entities("main.go", ast, source)

      assert length(entities) == 1
      entity = hd(entities)
      assert entity.name == "main"
      assert entity.entity_type == :function
      assert entity.file_path == "main.go"
      assert entity.start_line == 1
      assert entity.end_line == 4
      assert entity.parameters == ["args"]
      assert entity.visibility == :public
      assert entity.language == :go
    end
  end

  describe "extract_entities/3 - Rust struct and impl" do
    test "extracts a Rust struct_item" do
      ast = %{
        "kind" => "source_file",
        "children" => [
          %{
            "kind" => "struct_item",
            "name" => "Config",
            "start_row" => 0,
            "end_row" => 4,
            "children" => []
          }
        ]
      }

      source = "struct Config {\n  host: String,\n  port: u16,\n}\n"
      entities = GenericExtractor.extract_entities("config.rs", ast, source)

      assert length(entities) == 1
      entity = hd(entities)
      assert entity.name == "Config"
      assert entity.entity_type == :struct
      assert entity.language == :rust
    end

    test "extracts a Rust impl_item" do
      ast = %{
        "kind" => "source_file",
        "children" => [
          %{
            "kind" => "impl_item",
            "name" => "Config",
            "start_row" => 0,
            "end_row" => 5,
            "children" => [
              %{
                "kind" => "function_item",
                "name" => "new",
                "start_row" => 1,
                "end_row" => 4,
                "children" => []
              }
            ]
          }
        ]
      }

      source = "impl Config {\n  fn new() -> Self {\n    Config { host: \"\".into(), port: 0 }\n  }\n}\n"
      entities = GenericExtractor.extract_entities("config.rs", ast, source)

      assert length(entities) == 2
      impl_entity = Enum.find(entities, &(&1.name == "Config"))
      fn_entity = Enum.find(entities, &(&1.name == "new"))
      assert impl_entity.entity_type == :module
      assert fn_entity.entity_type == :function
      assert impl_entity.contains == ["new"]
    end
  end

  describe "extract_entities/3 - Java class" do
    test "extracts a Java class declaration" do
      ast = %{
        "kind" => "program",
        "children" => [
          %{
            "kind" => "class_declaration",
            "name" => "UserService",
            "start_row" => 0,
            "end_row" => 10,
            "children" => [
              %{
                "kind" => "method_declaration",
                "name" => "getUser",
                "start_row" => 2,
                "end_row" => 5,
                "children" => [
                  %{
                    "kind" => "formal_parameters",
                    "children" => [
                      %{"kind" => "identifier", "name" => "id", "text" => "id"}
                    ]
                  }
                ]
              }
            ]
          }
        ]
      }

      source = String.duplicate("line\n", 11)
      entities = GenericExtractor.extract_entities("UserService.java", ast, source)

      assert length(entities) == 2
      class_entity = Enum.find(entities, &(&1.name == "UserService"))
      method_entity = Enum.find(entities, &(&1.name == "getUser"))
      assert class_entity.entity_type == :class
      assert class_entity.language == :java
      assert class_entity.contains == ["getUser"]
      assert method_entity.entity_type == :method
    end
  end

  describe "extract_entities/3 - import extraction" do
    test "extracts Go import declarations" do
      ast = %{
        "kind" => "source_file",
        "children" => [
          %{
            "kind" => "function_declaration",
            "name" => "handler",
            "start_row" => 5,
            "end_row" => 10,
            "children" => [
              %{
                "kind" => "import_declaration",
                "children" => [
                  %{"kind" => "interpreted_string_literal", "text" => "\"fmt\""}
                ]
              }
            ]
          }
        ]
      }

      source = String.duplicate("line\n", 11)
      entities = GenericExtractor.extract_entities("main.go", ast, source)

      entity = hd(entities)
      assert "fmt" in entity.is_a
    end

    test "extracts Rust use declaration" do
      ast = %{
        "kind" => "source_file",
        "children" => [
          %{
            "kind" => "function_item",
            "name" => "run",
            "start_row" => 0,
            "end_row" => 5,
            "children" => [
              %{
                "kind" => "use_declaration",
                "children" => [
                  %{"kind" => "scoped_identifier", "text" => "std::io::Read"}
                ]
              }
            ]
          }
        ]
      }

      source = String.duplicate("line\n", 6)
      entities = GenericExtractor.extract_entities("lib.rs", ast, source)

      entity = hd(entities)
      assert "std::io::Read" in entity.is_a
    end

    test "extracts Java import statement" do
      ast = %{
        "kind" => "program",
        "children" => [
          %{
            "kind" => "class_declaration",
            "name" => "App",
            "start_row" => 2,
            "end_row" => 8,
            "children" => [
              %{
                "kind" => "import_declaration",
                "children" => [
                  %{"kind" => "scoped_identifier", "text" => "java.util.List"}
                ]
              }
            ]
          }
        ]
      }

      source = String.duplicate("line\n", 9)
      entities = GenericExtractor.extract_entities("App.java", ast, source)

      entity = hd(entities)
      assert "java.util.List" in entity.is_a
    end
  end

  describe "extract_entities/3 - call extraction" do
    test "extracts calls from nested AST children" do
      ast = %{
        "kind" => "source_file",
        "children" => [
          %{
            "kind" => "function_declaration",
            "name" => "process",
            "start_row" => 0,
            "end_row" => 5,
            "children" => [
              %{
                "kind" => "expression_statement",
                "children" => [
                  %{"kind" => "call_expression", "name" => "fmt.Println"},
                  %{"kind" => "call_expression", "name" => "doWork"}
                ]
              }
            ]
          }
        ]
      }

      source = String.duplicate("line\n", 6)
      entities = GenericExtractor.extract_entities("main.go", ast, source)

      entity = hd(entities)
      assert "fmt.Println" in entity.calls
      assert "doWork" in entity.calls
    end
  end

  describe "extract_entities/3 - parameter extraction" do
    test "extracts parameters from parameter_list children" do
      ast = %{
        "kind" => "source_file",
        "children" => [
          %{
            "kind" => "function_declaration",
            "name" => "add",
            "start_row" => 0,
            "end_row" => 2,
            "children" => [
              %{
                "kind" => "parameter_list",
                "children" => [
                  %{"kind" => "identifier", "name" => "a", "text" => "a"},
                  %{"kind" => "identifier", "name" => "b", "text" => "b"}
                ]
              }
            ]
          }
        ]
      }

      source = "func add(a, b int) int {\n  return a + b\n}\n"
      entities = GenericExtractor.extract_entities("math.go", ast, source)

      entity = hd(entities)
      assert entity.parameters == ["a", "b"]
    end
  end

  describe "extract_entities/3 - edge cases" do
    test "empty AST returns empty list" do
      ast = %{"kind" => "source_file", "children" => []}
      assert GenericExtractor.extract_entities("empty.go", ast, "") == []
    end

    test "AST with no children key returns empty list" do
      ast = %{"kind" => "source_file"}
      assert GenericExtractor.extract_entities("empty.go", ast, "") == []
    end

    test "deeply nested AST extracts all definitions" do
      ast = %{
        "kind" => "source_file",
        "children" => [
          %{
            "kind" => "class_declaration",
            "name" => "Outer",
            "start_row" => 0,
            "end_row" => 20,
            "children" => [
              %{
                "kind" => "class_declaration",
                "name" => "Inner",
                "start_row" => 2,
                "end_row" => 10,
                "children" => [
                  %{
                    "kind" => "method_declaration",
                    "name" => "doStuff",
                    "start_row" => 4,
                    "end_row" => 8,
                    "children" => []
                  }
                ]
              }
            ]
          }
        ]
      }

      source = String.duplicate("line\n", 21)
      entities = GenericExtractor.extract_entities("Outer.java", ast, source)

      names = Enum.map(entities, & &1.name) |> Enum.sort()
      assert "Outer" in names
      assert "Inner" in names
      assert "doStuff" in names
      assert length(entities) == 3
    end

    test "nodes without names are filtered out" do
      ast = %{
        "kind" => "source_file",
        "children" => [
          %{
            "kind" => "function_declaration",
            "start_row" => 0,
            "end_row" => 2,
            "children" => []
          },
          %{
            "kind" => "function_declaration",
            "name" => "valid",
            "start_row" => 3,
            "end_row" => 5,
            "children" => []
          }
        ]
      }

      source = String.duplicate("line\n", 6)
      entities = GenericExtractor.extract_entities("test.go", ast, source)

      assert length(entities) == 1
      assert hd(entities).name == "valid"
    end
  end

  describe "extract_entities/3 - Swift property_declaration" do
    test "property_declaration is classified as variable, not function" do
      ast = %{
        "kind" => "source_file",
        "children" => [
          %{
            "kind" => "property_declaration",
            "name" => "g",
            "start_row" => 0,
            "end_row" => 0,
            "children" => []
          }
        ]
      }

      entities = GenericExtractor.extract_entities("Foo.swift", ast, "let g = 42")
      assert length(entities) == 1
      entity = hd(entities)
      assert entity.name == "g"
      assert entity.entity_type == :variable,
             "property_declaration should be :variable, not :function — got: #{entity.entity_type}"
    end
  end
end
