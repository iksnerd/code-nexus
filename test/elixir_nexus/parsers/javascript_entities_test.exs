defmodule ElixirNexus.Parsers.JavaScriptEntitiesTest do
  use ExUnit.Case, async: true

  alias ElixirNexus.Parsers.JavaScriptExtractor

  # Helper to build a minimal AST node
  defp make_node(kind, opts \\ []) do
    %{
      "kind" => kind,
      "start_row" => Keyword.get(opts, :start_row, 0),
      "end_row" => Keyword.get(opts, :end_row, 0),
      "start_col" => 0,
      "end_col" => 0,
      "text" => Keyword.get(opts, :text, ""),
      "children" => Keyword.get(opts, :children, [])
    }
    |> maybe_put("name", Keyword.get(opts, :name))
    |> maybe_put("fields", Keyword.get(opts, :fields))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  describe "entity type classification" do
    test "function_declaration is classified as function" do
      ast =
        make_node("program",
          children: [
            make_node("function_declaration",
              name: "greet",
              children: [
                make_node("formal_parameters", children: []),
                make_node("statement_block", children: [])
              ]
            )
          ]
        )

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "function greet() {}")
      func = Enum.find(entities, &(&1.name == "greet"))

      assert func != nil
      assert func.entity_type == :function
    end

    test "lexical_declaration with arrow function is classified as function" do
      ast =
        make_node("program",
          children: [
            make_node("lexical_declaration",
              children: [
                make_node("variable_declarator",
                  name: "handler",
                  children: [
                    make_node("identifier", text: "handler"),
                    make_node("arrow_function",
                      children: [
                        make_node("formal_parameters", children: []),
                        make_node("statement_block", children: [])
                      ]
                    )
                  ]
                )
              ]
            )
          ]
        )

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "const handler = () => {}")
      func = Enum.find(entities, &(&1.name == "handler"))

      assert func != nil
      assert func.entity_type == :function
    end

    test "lexical_declaration with object literal is classified as variable" do
      ast =
        make_node("program",
          children: [
            make_node("lexical_declaration",
              children: [
                make_node("variable_declarator",
                  name: "Config",
                  children: [
                    make_node("identifier", text: "Config"),
                    make_node("object", children: [])
                  ]
                )
              ]
            )
          ]
        )

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "const Config = {}")
      var = Enum.find(entities, &(&1.name == "Config"))

      assert var != nil
      assert var.entity_type == :variable
    end

    test "variable_declaration with plain value is classified as variable" do
      ast =
        make_node("program",
          children: [
            make_node("variable_declaration",
              children: [
                make_node("variable_declarator",
                  name: "count",
                  children: [
                    make_node("identifier", text: "count"),
                    make_node("number", text: "42")
                  ]
                )
              ]
            )
          ]
        )

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "var count = 42")
      var = Enum.find(entities, &(&1.name == "count"))

      assert var != nil
      assert var.entity_type == :variable
    end

    test "class_declaration is classified as class" do
      ast =
        make_node("program",
          children: [
            make_node("class_declaration", name: "Foo", children: [])
          ]
        )

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "class Foo {}")
      cls = Enum.find(entities, &(&1.name == "Foo"))

      assert cls != nil
      assert cls.entity_type == :class
    end
  end

  describe "interface and type alias extraction" do
    test "interface_declaration is classified as interface" do
      ast =
        make_node("program",
          children: [
            make_node("interface_declaration",
              name: "Props",
              children: [
                make_node("object_type", children: [])
              ]
            )
          ]
        )

      entities = JavaScriptExtractor.extract_entities("test.ts", ast, "interface Props {}")
      iface = Enum.find(entities, &(&1.name == "Props"))

      assert iface != nil
      assert iface.entity_type == :interface
      assert iface.visibility == :public
    end

    test "type_alias_declaration is classified as struct" do
      ast =
        make_node("program",
          children: [
            make_node("type_alias_declaration",
              name: "Config",
              children: [
                make_node("object_type", children: [])
              ]
            )
          ]
        )

      entities = JavaScriptExtractor.extract_entities("test.ts", ast, "type Config = {}")
      ta = Enum.find(entities, &(&1.name == "Config"))

      assert ta != nil
      assert ta.entity_type == :struct
      assert ta.visibility == :public
    end
  end

  describe "method extraction" do
    test "method_definition inside class is extracted" do
      ast =
        make_node("program",
          children: [
            make_node("class_declaration",
              name: "Widget",
              children: [
                make_node("method_definition",
                  name: "render",
                  children: [
                    make_node("formal_parameters", children: []),
                    make_node("statement_block", children: [])
                  ]
                )
              ]
            )
          ]
        )

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "class Widget { render() {} }")
      method = Enum.find(entities, &(&1.name == "render"))

      assert method != nil
      assert method.entity_type == :method
    end
  end

  describe "function expression classification" do
    test "lexical_declaration with function_expression is classified as function" do
      ast =
        make_node("program",
          children: [
            make_node("lexical_declaration",
              children: [
                make_node("variable_declarator",
                  name: "handler",
                  children: [
                    make_node("identifier", text: "handler"),
                    make_node("function_expression",
                      children: [
                        make_node("formal_parameters", children: []),
                        make_node("statement_block", children: [])
                      ]
                    )
                  ]
                )
              ]
            )
          ]
        )

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "const handler = function() {}")
      func = Enum.find(entities, &(&1.name == "handler"))

      assert func != nil
      assert func.entity_type == :function
    end

    test "lexical_declaration with class_expression is classified as class" do
      ast =
        make_node("program",
          children: [
            make_node("lexical_declaration",
              children: [
                make_node("variable_declarator",
                  name: "Widget",
                  children: [
                    make_node("identifier", text: "Widget"),
                    make_node("class_expression", children: [])
                  ]
                )
              ]
            )
          ]
        )

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "const Widget = class {}")
      cls = Enum.find(entities, &(&1.name == "Widget"))

      assert cls != nil
      assert cls.entity_type == :class
    end
  end

  describe "parameter extraction" do
    test "required_parameter is extracted" do
      ast =
        make_node("program",
          children: [
            make_node("function_declaration",
              name: "greet",
              children: [
                make_node("formal_parameters",
                  children: [
                    make_node("required_parameter", name: "name", text: "name")
                  ]
                ),
                make_node("statement_block", children: [])
              ]
            )
          ]
        )

      entities = JavaScriptExtractor.extract_entities("test.ts", ast, "function greet(name: string) {}")
      func = Enum.find(entities, &(&1.name == "greet"))

      assert func != nil
      assert "name" in func.parameters
    end

    test "optional_parameter is extracted" do
      ast =
        make_node("program",
          children: [
            make_node("function_declaration",
              name: "greet",
              children: [
                make_node("formal_parameters",
                  children: [
                    make_node("optional_parameter", name: "name", text: "name")
                  ]
                ),
                make_node("statement_block", children: [])
              ]
            )
          ]
        )

      entities = JavaScriptExtractor.extract_entities("test.ts", ast, "function greet(name?: string) {}")
      func = Enum.find(entities, &(&1.name == "greet"))

      assert func != nil
      assert "name" in func.parameters
    end
  end

  describe "class extends and contains" do
    test "class with extends_clause has is_a" do
      ast =
        make_node("program",
          children: [
            make_node("class_declaration",
              name: "Dog",
              children: [
                make_node("extends_clause",
                  children: [
                    make_node("identifier", text: "Animal")
                  ]
                ),
                make_node("method_definition", name: "bark", children: [])
              ]
            )
          ]
        )

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "class Dog extends Animal { bark() {} }")
      cls = Enum.find(entities, &(&1.name == "Dog"))

      assert cls != nil
      assert "Animal" in cls.is_a
      assert "bark" in cls.contains
    end
  end

  describe "default export extraction" do
    test "export default identifier is extracted" do
      ast =
        make_node("program",
          children: [
            make_node("function_declaration",
              name: "main",
              children: [
                make_node("formal_parameters", children: []),
                make_node("statement_block", children: [])
              ]
            ),
            make_node("export_statement",
              children: [
                make_node("identifier", text: "main")
              ]
            )
          ]
        )

      exports = JavaScriptExtractor.extract_exports(ast)
      assert "main" in exports
    end
  end

  describe "walk_ast edge cases" do
    test "node without children field is handled" do
      ast =
        make_node("program",
          children: [
            %{
              "kind" => "function_declaration",
              "name" => "simple",
              "start_row" => 0,
              "end_row" => 0,
              "start_col" => 0,
              "end_col" => 0,
              "text" => ""
            }
          ]
        )

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "function simple() {}")
      func = Enum.find(entities, &(&1.name == "simple"))

      assert func != nil
      assert func.entity_type == :function
    end

    test "file without imports or exports has no module entity" do
      ast =
        make_node("program",
          children: [
            make_node("function_declaration",
              name: "solo",
              children: [
                make_node("formal_parameters", children: []),
                make_node("statement_block", children: [])
              ]
            )
          ]
        )

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "function solo() {}")
      mod = Enum.find(entities, &(&1.entity_type == :module))

      assert mod == nil
    end
  end

  describe "extract_name_from_fields" do
    test "extracts name from fields map" do
      ast =
        make_node("program",
          children: [
            make_node("function_declaration",
              fields: %{"name" => "myFunc"},
              children: [
                make_node("formal_parameters", children: []),
                make_node("statement_block", children: [])
              ]
            )
          ]
        )

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "function myFunc() {}")
      func = Enum.find(entities, &(&1.name == "myFunc"))
      assert func != nil
    end
  end

  describe "variable_declaration type" do
    test "variable_declaration with function expression" do
      ast =
        make_node("program",
          children: [
            make_node("variable_declaration",
              children: [
                make_node("variable_declarator",
                  name: "handler",
                  children: [
                    make_node("identifier", text: "handler"),
                    make_node("function_expression",
                      children: [
                        make_node("formal_parameters", children: []),
                        make_node("statement_block", children: [])
                      ]
                    )
                  ]
                )
              ]
            )
          ]
        )

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "var handler = function() {}")
      func = Enum.find(entities, &(&1.name == "handler"))

      assert func != nil
      assert func.entity_type == :function
    end
  end

  describe "implements_clause extraction" do
    test "class with implements_clause has is_a" do
      ast =
        make_node("program",
          children: [
            make_node("class_declaration",
              name: "Service",
              children: [
                make_node("implements_clause",
                  children: [
                    make_node("identifier", text: "IService")
                  ]
                )
              ]
            )
          ]
        )

      entities = JavaScriptExtractor.extract_entities("test.ts", ast, "class Service implements IService {}")
      cls = Enum.find(entities, &(&1.name == "Service"))

      assert cls != nil
      assert "IService" in cls.is_a
    end
  end

  describe "arrow function context" do
    test "standalone arrow function without name context is skipped" do
      ast =
        make_node("program",
          children: [
            make_node("expression_statement",
              children: [
                make_node("arrow_function",
                  children: [
                    make_node("formal_parameters", children: []),
                    make_node("statement_block", children: [])
                  ]
                )
              ]
            )
          ]
        )

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "() => {}")
      # Unnamed arrow functions should not create entities
      assert Enum.empty?(entities) or not Enum.any?(entities, &(&1.entity_type == :function))
    end
  end

  describe "node without children in walk_ast" do
    test "interface_declaration without children field is handled" do
      ast =
        make_node("program",
          children: [
            %{
              "kind" => "interface_declaration",
              "name" => "IFoo",
              "start_row" => 0,
              "end_row" => 0,
              "start_col" => 0,
              "end_col" => 0,
              "text" => ""
            }
          ]
        )

      entities = JavaScriptExtractor.extract_entities("test.ts", ast, "interface IFoo {}")
      iface = Enum.find(entities, &(&1.name == "IFoo"))

      assert iface != nil
      assert iface.entity_type == :interface
    end
  end
end
