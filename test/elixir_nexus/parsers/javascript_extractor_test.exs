defmodule ElixirNexus.Parsers.JavaScriptExtractorTest do
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
      ast = make_node("program", children: [
        make_node("function_declaration", name: "greet", children: [
          make_node("formal_parameters", children: []),
          make_node("statement_block", children: [])
        ])
      ])

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "function greet() {}")
      func = Enum.find(entities, &(&1.name == "greet"))

      assert func != nil
      assert func.entity_type == :function
    end

    test "lexical_declaration with arrow function is classified as function" do
      ast = make_node("program", children: [
        make_node("lexical_declaration", children: [
          make_node("variable_declarator", name: "handler", children: [
            make_node("identifier", text: "handler"),
            make_node("arrow_function", children: [
              make_node("formal_parameters", children: []),
              make_node("statement_block", children: [])
            ])
          ])
        ])
      ])

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "const handler = () => {}")
      func = Enum.find(entities, &(&1.name == "handler"))

      assert func != nil
      assert func.entity_type == :function
    end

    test "lexical_declaration with object literal is classified as variable" do
      ast = make_node("program", children: [
        make_node("lexical_declaration", children: [
          make_node("variable_declarator", name: "Config", children: [
            make_node("identifier", text: "Config"),
            make_node("object", children: [])
          ])
        ])
      ])

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "const Config = {}")
      var = Enum.find(entities, &(&1.name == "Config"))

      assert var != nil
      assert var.entity_type == :variable
    end

    test "variable_declaration with plain value is classified as variable" do
      ast = make_node("program", children: [
        make_node("variable_declaration", children: [
          make_node("variable_declarator", name: "count", children: [
            make_node("identifier", text: "count"),
            make_node("number", text: "42")
          ])
        ])
      ])

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "var count = 42")
      var = Enum.find(entities, &(&1.name == "count"))

      assert var != nil
      assert var.entity_type == :variable
    end

    test "class_declaration is classified as class" do
      ast = make_node("program", children: [
        make_node("class_declaration", name: "Foo", children: [])
      ])

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "class Foo {}")
      cls = Enum.find(entities, &(&1.name == "Foo"))

      assert cls != nil
      assert cls.entity_type == :class
    end
  end

  describe "call extraction" do
    test "simple function call is extracted" do
      ast = make_node("program", children: [
        make_node("function_declaration", name: "main", children: [
          make_node("formal_parameters", children: []),
          make_node("statement_block", children: [
            make_node("expression_statement", children: [
              make_node("call_expression", children: [
                make_node("identifier", text: "doStuff"),
                make_node("arguments", children: [])
              ])
            ])
          ])
        ])
      ])

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "function main() { doStuff() }")
      func = Enum.find(entities, &(&1.name == "main"))

      assert "doStuff" in func.calls
    end

    test "chained calls do not produce duplicates" do
      # Simulates: db.collection("x").doc("y")
      inner_call = make_node("call_expression", children: [
        make_node("member_expression", children: [
          make_node("identifier", text: "db"),
          make_node("property_identifier", text: "collection")
        ]),
        make_node("arguments", children: [
          make_node("string", text: "\"x\"")
        ])
      ])

      outer_call = make_node("call_expression", children: [
        make_node("member_expression", children: [
          inner_call,
          make_node("property_identifier", text: "doc")
        ]),
        make_node("arguments", children: [
          make_node("string", text: "\"y\"")
        ])
      ])

      ast = make_node("program", children: [
        make_node("function_declaration", name: "query", children: [
          make_node("formal_parameters", children: []),
          make_node("statement_block", children: [
            make_node("expression_statement", children: [outer_call])
          ])
        ])
      ])

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "function query() { db.collection(\"x\").doc(\"y\") }")
      func = Enum.find(entities, &(&1.name == "query"))

      # Each call name should appear exactly once
      call_counts = Enum.frequencies(func.calls)
      for {name, count} <- call_counts do
        assert count == 1, "Call '#{name}' appeared #{count} times, expected 1"
      end
    end

    test "new expression is extracted" do
      ast = make_node("program", children: [
        make_node("function_declaration", name: "init", children: [
          make_node("formal_parameters", children: []),
          make_node("statement_block", children: [
            make_node("expression_statement", children: [
              make_node("new_expression", children: [
                make_node("identifier", text: "Foo"),
                make_node("arguments", children: [])
              ])
            ])
          ])
        ])
      ])

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "function init() { new Foo() }")
      func = Enum.find(entities, &(&1.name == "init"))

      assert "Foo" in func.calls
    end
  end

  describe "import extraction" do
    test "extracts import source paths" do
      ast = make_node("program", children: [
        make_node("import_statement", children: [
          make_node("import_clause", children: [
            make_node("named_imports", children: [
              make_node("import_specifier", name: "useState", children: [
                make_node("identifier", text: "useState")
              ])
            ])
          ]),
          make_node("string", text: "", children: [
            make_node("string_fragment", text: "react")
          ])
        ])
      ])

      imports = JavaScriptExtractor.extract_imports(ast)
      assert "react" in imports
    end
  end

  describe "interface and type alias extraction" do
    test "interface_declaration is classified as interface" do
      ast = make_node("program", children: [
        make_node("interface_declaration", name: "Props", children: [
          make_node("object_type", children: [])
        ])
      ])

      entities = JavaScriptExtractor.extract_entities("test.ts", ast, "interface Props {}")
      iface = Enum.find(entities, &(&1.name == "Props"))

      assert iface != nil
      assert iface.entity_type == :interface
      assert iface.visibility == :public
    end

    test "type_alias_declaration is classified as struct" do
      ast = make_node("program", children: [
        make_node("type_alias_declaration", name: "Config", children: [
          make_node("object_type", children: [])
        ])
      ])

      entities = JavaScriptExtractor.extract_entities("test.ts", ast, "type Config = {}")
      ta = Enum.find(entities, &(&1.name == "Config"))

      assert ta != nil
      assert ta.entity_type == :struct
      assert ta.visibility == :public
    end
  end

  describe "method extraction" do
    test "method_definition inside class is extracted" do
      ast = make_node("program", children: [
        make_node("class_declaration", name: "Widget", children: [
          make_node("method_definition", name: "render", children: [
            make_node("formal_parameters", children: []),
            make_node("statement_block", children: [])
          ])
        ])
      ])

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "class Widget { render() {} }")
      method = Enum.find(entities, &(&1.name == "render"))

      assert method != nil
      assert method.entity_type == :method
    end
  end

  describe "function expression classification" do
    test "lexical_declaration with function_expression is classified as function" do
      ast = make_node("program", children: [
        make_node("lexical_declaration", children: [
          make_node("variable_declarator", name: "handler", children: [
            make_node("identifier", text: "handler"),
            make_node("function_expression", children: [
              make_node("formal_parameters", children: []),
              make_node("statement_block", children: [])
            ])
          ])
        ])
      ])

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "const handler = function() {}")
      func = Enum.find(entities, &(&1.name == "handler"))

      assert func != nil
      assert func.entity_type == :function
    end

    test "lexical_declaration with class_expression is classified as class" do
      ast = make_node("program", children: [
        make_node("lexical_declaration", children: [
          make_node("variable_declarator", name: "Widget", children: [
            make_node("identifier", text: "Widget"),
            make_node("class_expression", children: [])
          ])
        ])
      ])

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "const Widget = class {}")
      cls = Enum.find(entities, &(&1.name == "Widget"))

      assert cls != nil
      assert cls.entity_type == :class
    end
  end

  describe "parameter extraction" do
    test "required_parameter is extracted" do
      ast = make_node("program", children: [
        make_node("function_declaration", name: "greet", children: [
          make_node("formal_parameters", children: [
            make_node("required_parameter", name: "name", text: "name")
          ]),
          make_node("statement_block", children: [])
        ])
      ])

      entities = JavaScriptExtractor.extract_entities("test.ts", ast, "function greet(name: string) {}")
      func = Enum.find(entities, &(&1.name == "greet"))

      assert func != nil
      assert "name" in func.parameters
    end

    test "optional_parameter is extracted" do
      ast = make_node("program", children: [
        make_node("function_declaration", name: "greet", children: [
          make_node("formal_parameters", children: [
            make_node("optional_parameter", name: "name", text: "name")
          ]),
          make_node("statement_block", children: [])
        ])
      ])

      entities = JavaScriptExtractor.extract_entities("test.ts", ast, "function greet(name?: string) {}")
      func = Enum.find(entities, &(&1.name == "greet"))

      assert func != nil
      assert "name" in func.parameters
    end
  end

  describe "class extends and contains" do
    test "class with extends_clause has is_a" do
      ast = make_node("program", children: [
        make_node("class_declaration", name: "Dog", children: [
          make_node("extends_clause", children: [
            make_node("identifier", text: "Animal")
          ]),
          make_node("method_definition", name: "bark", children: [])
        ])
      ])

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "class Dog extends Animal { bark() {} }")
      cls = Enum.find(entities, &(&1.name == "Dog"))

      assert cls != nil
      assert "Animal" in cls.is_a
      assert "bark" in cls.contains
    end
  end

  describe "default export extraction" do
    test "export default identifier is extracted" do
      ast = make_node("program", children: [
        make_node("function_declaration", name: "main", children: [
          make_node("formal_parameters", children: []),
          make_node("statement_block", children: [])
        ]),
        make_node("export_statement", children: [
          make_node("identifier", text: "main")
        ])
      ])

      exports = JavaScriptExtractor.extract_exports(ast)
      assert "main" in exports
    end
  end

  describe "exported interface and type alias" do
    test "exported interface is extracted and marked public" do
      ast = make_node("program", children: [
        make_node("export_statement", children: [
          make_node("interface_declaration", name: "ApiResponse", children: [
            make_node("object_type", children: [])
          ])
        ])
      ])

      entities = JavaScriptExtractor.extract_entities("test.ts", ast, "export interface ApiResponse {}")
      iface = Enum.find(entities, &(&1.name == "ApiResponse"))

      assert iface != nil
      assert iface.entity_type == :interface
      assert iface.visibility == :public
    end

    test "exported type alias is extracted and marked public" do
      ast = make_node("program", children: [
        make_node("export_statement", children: [
          make_node("type_alias_declaration", name: "ID", children: [
            make_node("predefined_type", text: "string")
          ])
        ])
      ])

      entities = JavaScriptExtractor.extract_entities("test.ts", ast, "export type ID = string")
      ta = Enum.find(entities, &(&1.name == "ID"))

      assert ta != nil
      assert ta.entity_type == :struct
      assert ta.visibility == :public
    end
  end

  describe "export extraction" do
    test "exported function is marked public" do
      ast = make_node("program", children: [
        make_node("export_statement", children: [
          make_node("function_declaration", name: "helper", children: [
            make_node("formal_parameters", children: []),
            make_node("statement_block", children: [])
          ])
        ])
      ])

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "export function helper() {}")
      func = Enum.find(entities, &(&1.name == "helper"))

      assert func != nil
      assert func.visibility == :public
    end

    test "exported variable declaration is extracted" do
      ast = make_node("program", children: [
        make_node("export_statement", children: [
          make_node("lexical_declaration", children: [
            make_node("variable_declarator", name: "API_URL", children: [
              make_node("identifier", text: "API_URL"),
              make_node("string", text: "\"https://api.example.com\"")
            ])
          ])
        ])
      ])

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "export const API_URL = \"https://api.example.com\"")
      var = Enum.find(entities, &(&1.name == "API_URL"))

      assert var != nil
      assert var.entity_type == :variable
      assert var.visibility == :public
    end

    test "export_clause extracts named exports" do
      ast = make_node("program", children: [
        make_node("function_declaration", name: "foo", children: [
          make_node("formal_parameters", children: []),
          make_node("statement_block", children: [])
        ]),
        make_node("export_statement", children: [
          make_node("export_clause", children: [
            make_node("identifier", text: "foo")
          ])
        ])
      ])

      exports = JavaScriptExtractor.extract_exports(ast)
      assert "foo" in exports
    end

    test "exported class is marked public" do
      ast = make_node("program", children: [
        make_node("export_statement", children: [
          make_node("class_declaration", name: "MyClass", children: [])
        ])
      ])

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "export class MyClass {}")
      cls = Enum.find(entities, &(&1.name == "MyClass"))

      assert cls != nil
      assert cls.entity_type == :class
      assert cls.visibility == :public
    end
  end

  describe "import identifiers extraction" do
    test "default import identifier is extracted" do
      ast = make_node("program", children: [
        make_node("import_statement", children: [
          make_node("import_clause", children: [
            make_node("identifier", text: "React")
          ]),
          make_node("string", text: "", children: [
            make_node("string_fragment", text: "react")
          ])
        ])
      ])

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "import React from 'react'")
      mod = Enum.find(entities, &(&1.entity_type == :module))

      assert mod != nil
      assert "React" in mod.calls
    end

    test "named imports create file-level module entity" do
      ast = make_node("program", children: [
        make_node("import_statement", children: [
          make_node("import_clause", children: [
            make_node("named_imports", children: [
              make_node("import_specifier", name: "useState", children: [
                make_node("identifier", text: "useState")
              ]),
              make_node("import_specifier", name: "useEffect", children: [
                make_node("identifier", text: "useEffect")
              ])
            ])
          ]),
          make_node("string", text: "", children: [
            make_node("string_fragment", text: "react")
          ])
        ])
      ])

      entities = JavaScriptExtractor.extract_entities("app.tsx", ast, "import { useState, useEffect } from 'react'")
      mod = Enum.find(entities, &(&1.entity_type == :module))

      assert mod != nil
      assert mod.name == "app"
      assert "react" in mod.is_a
      assert "useState" in mod.calls
      assert "useEffect" in mod.calls
    end
  end

  describe "walk_ast edge cases" do
    test "node without children field is handled" do
      ast = make_node("program", children: [
        %{"kind" => "function_declaration", "name" => "simple", "start_row" => 0, "end_row" => 0, "start_col" => 0, "end_col" => 0, "text" => ""}
      ])

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "function simple() {}")
      func = Enum.find(entities, &(&1.name == "simple"))

      assert func != nil
      assert func.entity_type == :function
    end

    test "file without imports or exports has no module entity" do
      ast = make_node("program", children: [
        make_node("function_declaration", name: "solo", children: [
          make_node("formal_parameters", children: []),
          make_node("statement_block", children: [])
        ])
      ])

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "function solo() {}")
      mod = Enum.find(entities, &(&1.entity_type == :module))

      assert mod == nil
    end
  end

  describe "callee name extraction" do
    test "member_expression with text field only" do
      ast = make_node("program", children: [
        make_node("function_declaration", name: "test", children: [
          make_node("formal_parameters", children: []),
          make_node("statement_block", children: [
            make_node("expression_statement", children: [
              make_node("call_expression", children: [
                %{"kind" => "member_expression", "text" => "console.log",
                  "start_row" => 0, "end_row" => 0, "start_col" => 0, "end_col" => 0},
                make_node("arguments", children: [])
              ])
            ])
          ])
        ])
      ])

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "function test() { console.log() }")
      func = Enum.find(entities, &(&1.name == "test"))

      assert func != nil
      assert "console.log" in func.calls
    end
  end

  describe "string value extraction" do
    test "string with direct text value" do
      ast = make_node("program", children: [
        make_node("import_statement", children: [
          make_node("import_clause", children: [
            make_node("identifier", text: "fs")
          ]),
          make_node("string", text: "'fs'")
        ])
      ])

      imports = JavaScriptExtractor.extract_imports(ast)
      assert "fs" in imports
    end
  end

  describe "extract_name_from_fields" do
    test "extracts name from fields map" do
      ast = make_node("program", children: [
        make_node("function_declaration",
          fields: %{"name" => "myFunc"},
          children: [
            make_node("formal_parameters", children: []),
            make_node("statement_block", children: [])
          ])
      ])

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "function myFunc() {}")
      func = Enum.find(entities, &(&1.name == "myFunc"))
      assert func != nil
    end
  end

  describe "export_clause with multiple identifiers" do
    test "extracts all named exports from export_clause" do
      ast = make_node("program", children: [
        make_node("function_declaration", name: "foo", children: [
          make_node("formal_parameters", children: []),
          make_node("statement_block", children: [])
        ]),
        make_node("function_declaration", name: "bar", children: [
          make_node("formal_parameters", children: []),
          make_node("statement_block", children: [])
        ]),
        make_node("export_statement", children: [
          make_node("export_clause", children: [
            make_node("identifier", text: "foo"),
            make_node("identifier", text: "bar")
          ])
        ])
      ])

      exports = JavaScriptExtractor.extract_exports(ast)
      assert "foo" in exports
      assert "bar" in exports
    end
  end

  describe "call_expression with direct name field" do
    test "extracts call name from name field directly" do
      ast = make_node("program", children: [
        make_node("function_declaration", name: "test", children: [
          make_node("formal_parameters", children: []),
          make_node("statement_block", children: [
            make_node("expression_statement", children: [
              %{"kind" => "call_expression", "name" => "directCall",
                "start_row" => 0, "end_row" => 0, "start_col" => 0, "end_col" => 0,
                "text" => "directCall()"}
            ])
          ])
        ])
      ])

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "function test() { directCall() }")
      func = Enum.find(entities, &(&1.name == "test"))
      assert func != nil
      assert "directCall" in func.calls
    end
  end

  describe "new_expression with member callee" do
    test "new expression with non-identifier callee" do
      ast = make_node("program", children: [
        make_node("function_declaration", name: "init", children: [
          make_node("formal_parameters", children: []),
          make_node("statement_block", children: [
            make_node("expression_statement", children: [
              make_node("new_expression", children: [
                make_node("member_expression", children: [
                  make_node("identifier", text: "ns"),
                  make_node("property_identifier", text: "Widget")
                ]),
                make_node("arguments", children: [])
              ])
            ])
          ])
        ])
      ])

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "function init() { new ns.Widget() }")
      func = Enum.find(entities, &(&1.name == "init"))
      assert func != nil
      # Should not crash even though callee is a member expression, not an identifier
      assert is_list(func.calls)
    end
  end

  describe "chained call member_expression callee" do
    test "extracts property from chained call expression" do
      # Simulates: foo().bar() — the member_expression has a call_expression child
      inner_call = make_node("call_expression", children: [
        make_node("identifier", text: "foo"),
        make_node("arguments", children: [])
      ])

      member = make_node("member_expression", children: [
        inner_call,
        make_node("property_identifier", text: "bar")
      ])

      outer_call = make_node("call_expression", children: [
        member,
        make_node("arguments", children: [])
      ])

      ast = make_node("program", children: [
        make_node("function_declaration", name: "chained", children: [
          make_node("formal_parameters", children: []),
          make_node("statement_block", children: [
            make_node("expression_statement", children: [outer_call])
          ])
        ])
      ])

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "function chained() { foo().bar() }")
      func = Enum.find(entities, &(&1.name == "chained"))

      assert func != nil
      assert "bar" in func.calls
      assert "foo" in func.calls
    end
  end

  describe "member_expression callee with text fallback" do
    test "extracts callee name from text when children are empty" do
      ast = make_node("program", children: [
        make_node("function_declaration", name: "test", children: [
          make_node("formal_parameters", children: []),
          make_node("statement_block", children: [
            make_node("expression_statement", children: [
              make_node("call_expression", children: [
                %{"kind" => "member_expression", "text" => "app.listen",
                  "start_row" => 0, "end_row" => 0, "start_col" => 0, "end_col" => 0},
                make_node("arguments", children: [])
              ])
            ])
          ])
        ])
      ])

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "function test() { app.listen() }")
      func = Enum.find(entities, &(&1.name == "test"))

      assert func != nil
      assert "app.listen" in func.calls
    end
  end

  describe "variable_declaration type" do
    test "variable_declaration with function expression" do
      ast = make_node("program", children: [
        make_node("variable_declaration", children: [
          make_node("variable_declarator", name: "handler", children: [
            make_node("identifier", text: "handler"),
            make_node("function_expression", children: [
              make_node("formal_parameters", children: []),
              make_node("statement_block", children: [])
            ])
          ])
        ])
      ])

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "var handler = function() {}")
      func = Enum.find(entities, &(&1.name == "handler"))

      assert func != nil
      assert func.entity_type == :function
    end
  end

  describe "implements_clause extraction" do
    test "class with implements_clause has is_a" do
      ast = make_node("program", children: [
        make_node("class_declaration", name: "Service", children: [
          make_node("implements_clause", children: [
            make_node("identifier", text: "IService")
          ])
        ])
      ])

      entities = JavaScriptExtractor.extract_entities("test.ts", ast, "class Service implements IService {}")
      cls = Enum.find(entities, &(&1.name == "Service"))

      assert cls != nil
      assert "IService" in cls.is_a
    end
  end

  describe "arrow function context" do
    test "standalone arrow function without name context is skipped" do
      ast = make_node("program", children: [
        make_node("expression_statement", children: [
          make_node("arrow_function", children: [
            make_node("formal_parameters", children: []),
            make_node("statement_block", children: [])
          ])
        ])
      ])

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "() => {}")
      # Unnamed arrow functions should not create entities
      assert Enum.empty?(entities) or not Enum.any?(entities, &(&1.entity_type == :function))
    end
  end

  describe "export_statement with variable_declaration" do
    test "exported variable_declaration is extracted" do
      ast = make_node("program", children: [
        make_node("export_statement", children: [
          make_node("variable_declaration", children: [
            make_node("variable_declarator", name: "MAX", children: [
              make_node("identifier", text: "MAX"),
              make_node("number", text: "100")
            ])
          ])
        ])
      ])

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "export var MAX = 100")
      var = Enum.find(entities, &(&1.name == "MAX"))

      assert var != nil
      assert var.entity_type == :variable
      assert var.visibility == :public
    end
  end

  describe "node without children in walk_ast" do
    test "interface_declaration without children field is handled" do
      ast = make_node("program", children: [
        %{"kind" => "interface_declaration", "name" => "IFoo",
          "start_row" => 0, "end_row" => 0, "start_col" => 0, "end_col" => 0, "text" => ""}
      ])

      entities = JavaScriptExtractor.extract_entities("test.ts", ast, "interface IFoo {}")
      iface = Enum.find(entities, &(&1.name == "IFoo"))

      assert iface != nil
      assert iface.entity_type == :interface
    end
  end
end
