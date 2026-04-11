defmodule ElixirNexus.Parsers.JavaScriptImportsExportsTest do
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

  describe "import extraction" do
    test "extracts import source paths" do
      ast =
        make_node("program",
          children: [
            make_node("import_statement",
              children: [
                make_node("import_clause",
                  children: [
                    make_node("named_imports",
                      children: [
                        make_node("import_specifier",
                          name: "useState",
                          children: [
                            make_node("identifier", text: "useState")
                          ]
                        )
                      ]
                    )
                  ]
                ),
                make_node("string",
                  text: "",
                  children: [
                    make_node("string_fragment", text: "react")
                  ]
                )
              ]
            )
          ]
        )

      imports = JavaScriptExtractor.extract_imports(ast)
      assert "react" in imports
    end
  end

  describe "exported interface and type alias" do
    test "exported interface is extracted and marked public" do
      ast =
        make_node("program",
          children: [
            make_node("export_statement",
              children: [
                make_node("interface_declaration",
                  name: "ApiResponse",
                  children: [
                    make_node("object_type", children: [])
                  ]
                )
              ]
            )
          ]
        )

      entities = JavaScriptExtractor.extract_entities("test.ts", ast, "export interface ApiResponse {}")
      iface = Enum.find(entities, &(&1.name == "ApiResponse"))

      assert iface != nil
      assert iface.entity_type == :interface
      assert iface.visibility == :public
    end

    test "exported type alias is extracted and marked public" do
      ast =
        make_node("program",
          children: [
            make_node("export_statement",
              children: [
                make_node("type_alias_declaration",
                  name: "ID",
                  children: [
                    make_node("predefined_type", text: "string")
                  ]
                )
              ]
            )
          ]
        )

      entities = JavaScriptExtractor.extract_entities("test.ts", ast, "export type ID = string")
      ta = Enum.find(entities, &(&1.name == "ID"))

      assert ta != nil
      assert ta.entity_type == :struct
      assert ta.visibility == :public
    end
  end

  describe "export extraction" do
    test "exported function is marked public" do
      ast =
        make_node("program",
          children: [
            make_node("export_statement",
              children: [
                make_node("function_declaration",
                  name: "helper",
                  children: [
                    make_node("formal_parameters", children: []),
                    make_node("statement_block", children: [])
                  ]
                )
              ]
            )
          ]
        )

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "export function helper() {}")
      func = Enum.find(entities, &(&1.name == "helper"))

      assert func != nil
      assert func.visibility == :public
    end

    test "exported variable declaration is extracted" do
      ast =
        make_node("program",
          children: [
            make_node("export_statement",
              children: [
                make_node("lexical_declaration",
                  children: [
                    make_node("variable_declarator",
                      name: "API_URL",
                      children: [
                        make_node("identifier", text: "API_URL"),
                        make_node("string", text: "\"https://api.example.com\"")
                      ]
                    )
                  ]
                )
              ]
            )
          ]
        )

      entities =
        JavaScriptExtractor.extract_entities("test.js", ast, "export const API_URL = \"https://api.example.com\"")

      var = Enum.find(entities, &(&1.name == "API_URL"))

      assert var != nil
      assert var.entity_type == :variable
      assert var.visibility == :public
    end

    test "export_clause extracts named exports" do
      ast =
        make_node("program",
          children: [
            make_node("function_declaration",
              name: "foo",
              children: [
                make_node("formal_parameters", children: []),
                make_node("statement_block", children: [])
              ]
            ),
            make_node("export_statement",
              children: [
                make_node("export_clause",
                  children: [
                    make_node("identifier", text: "foo")
                  ]
                )
              ]
            )
          ]
        )

      exports = JavaScriptExtractor.extract_exports(ast)
      assert "foo" in exports
    end

    test "exported class is marked public" do
      ast =
        make_node("program",
          children: [
            make_node("export_statement",
              children: [
                make_node("class_declaration", name: "MyClass", children: [])
              ]
            )
          ]
        )

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "export class MyClass {}")
      cls = Enum.find(entities, &(&1.name == "MyClass"))

      assert cls != nil
      assert cls.entity_type == :class
      assert cls.visibility == :public
    end
  end

  describe "import identifiers extraction" do
    test "default import identifier is extracted" do
      ast =
        make_node("program",
          children: [
            make_node("import_statement",
              children: [
                make_node("import_clause",
                  children: [
                    make_node("identifier", text: "React")
                  ]
                ),
                make_node("string",
                  text: "",
                  children: [
                    make_node("string_fragment", text: "react")
                  ]
                )
              ]
            )
          ]
        )

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "import React from 'react'")
      mod = Enum.find(entities, &(&1.entity_type == :module))

      assert mod != nil
      assert "React" in mod.calls
    end

    test "named imports create file-level module entity" do
      ast =
        make_node("program",
          children: [
            make_node("import_statement",
              children: [
                make_node("import_clause",
                  children: [
                    make_node("named_imports",
                      children: [
                        make_node("import_specifier",
                          name: "useState",
                          children: [
                            make_node("identifier", text: "useState")
                          ]
                        ),
                        make_node("import_specifier",
                          name: "useEffect",
                          children: [
                            make_node("identifier", text: "useEffect")
                          ]
                        )
                      ]
                    )
                  ]
                ),
                make_node("string",
                  text: "",
                  children: [
                    make_node("string_fragment", text: "react")
                  ]
                )
              ]
            )
          ]
        )

      entities = JavaScriptExtractor.extract_entities("app.tsx", ast, "import { useState, useEffect } from 'react'")
      mod = Enum.find(entities, &(&1.entity_type == :module))

      assert mod != nil
      assert mod.name == "app"
      assert "react" in mod.is_a
      assert "useState" in mod.calls
      assert "useEffect" in mod.calls
    end
  end

  describe "string value extraction" do
    test "string with direct text value" do
      ast =
        make_node("program",
          children: [
            make_node("import_statement",
              children: [
                make_node("import_clause",
                  children: [
                    make_node("identifier", text: "fs")
                  ]
                ),
                make_node("string", text: "'fs'")
              ]
            )
          ]
        )

      imports = JavaScriptExtractor.extract_imports(ast)
      assert "fs" in imports
    end
  end

  describe "export_clause with multiple identifiers" do
    test "extracts all named exports from export_clause" do
      ast =
        make_node("program",
          children: [
            make_node("function_declaration",
              name: "foo",
              children: [
                make_node("formal_parameters", children: []),
                make_node("statement_block", children: [])
              ]
            ),
            make_node("function_declaration",
              name: "bar",
              children: [
                make_node("formal_parameters", children: []),
                make_node("statement_block", children: [])
              ]
            ),
            make_node("export_statement",
              children: [
                make_node("export_clause",
                  children: [
                    make_node("identifier", text: "foo"),
                    make_node("identifier", text: "bar")
                  ]
                )
              ]
            )
          ]
        )

      exports = JavaScriptExtractor.extract_exports(ast)
      assert "foo" in exports
      assert "bar" in exports
    end
  end

  describe "export_statement with variable_declaration" do
    test "exported variable_declaration is extracted" do
      ast =
        make_node("program",
          children: [
            make_node("export_statement",
              children: [
                make_node("variable_declaration",
                  children: [
                    make_node("variable_declarator",
                      name: "MAX",
                      children: [
                        make_node("identifier", text: "MAX"),
                        make_node("number", text: "100")
                      ]
                    )
                  ]
                )
              ]
            )
          ]
        )

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "export var MAX = 100")
      var = Enum.find(entities, &(&1.name == "MAX"))

      assert var != nil
      assert var.entity_type == :variable
      assert var.visibility == :public
    end
  end
end
