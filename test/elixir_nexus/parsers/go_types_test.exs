defmodule ElixirNexus.Parsers.GoTypesTest do
  use ExUnit.Case, async: true

  alias ElixirNexus.Parsers.GoExtractor

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
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Helper to wrap nodes in a source_file root
  defp wrap_program(children) do
    make_node("source_file", children: children)
  end

  describe "type declarations" do
    test "extracts struct type with fields" do
      ast =
        wrap_program([
          make_node("type_declaration",
            children: [
              make_node("type_spec",
                start_row: 0,
                end_row: 4,
                children: [
                  make_node("type_identifier", text: "Server"),
                  make_node("struct_type",
                    children: [
                      make_node("field_declaration",
                        children: [
                          make_node("field_identifier", text: "Host")
                        ]
                      ),
                      make_node("field_declaration",
                        children: [
                          make_node("field_identifier", text: "Port")
                        ]
                      )
                    ]
                  )
                ]
              )
            ]
          )
        ])

      source = "type Server struct {\n  Host string\n  Port int\n}"
      entities = GoExtractor.extract_entities("server.go", ast, source)
      struct = Enum.find(entities, &(&1.name == "Server" && &1.entity_type == :struct))

      assert struct != nil
      assert struct.entity_type == :struct
      assert struct.visibility == :public
      assert "Host" in struct.contains
      assert "Port" in struct.contains
    end

    test "extracts interface type with methods" do
      ast =
        wrap_program([
          make_node("type_declaration",
            children: [
              make_node("type_spec",
                start_row: 0,
                end_row: 3,
                children: [
                  make_node("type_identifier", text: "Reader"),
                  make_node("interface_type",
                    children: [
                      make_node("method_spec",
                        children: [
                          make_node("field_identifier", text: "Read")
                        ]
                      ),
                      make_node("method_spec",
                        children: [
                          make_node("field_identifier", text: "Close")
                        ]
                      )
                    ]
                  )
                ]
              )
            ]
          )
        ])

      source = "type Reader interface {\n  Read() error\n  Close() error\n}"
      entities = GoExtractor.extract_entities("io.go", ast, source)
      iface = Enum.find(entities, &(&1.name == "Reader"))

      assert iface != nil
      assert iface.entity_type == :interface
      assert "Read" in iface.contains
      assert "Close" in iface.contains
    end

    test "unexported struct has private visibility" do
      ast =
        wrap_program([
          make_node("type_declaration",
            children: [
              make_node("type_spec",
                start_row: 0,
                end_row: 2,
                children: [
                  make_node("type_identifier", text: "config"),
                  make_node("struct_type", children: [])
                ]
              )
            ]
          )
        ])

      entities = GoExtractor.extract_entities("config.go", ast, "type config struct {}")
      struct = Enum.find(entities, &(&1.name == "config"))

      assert struct != nil
      assert struct.visibility == :private
    end

    test "type spec without struct or interface defaults to struct" do
      ast =
        wrap_program([
          make_node("type_declaration",
            children: [
              make_node("type_spec",
                start_row: 0,
                end_row: 0,
                children: [
                  make_node("type_identifier", text: "ID"),
                  make_node("primitive_type", text: "int64")
                ]
              )
            ]
          )
        ])

      entities = GoExtractor.extract_entities("types.go", ast, "type ID int64")
      typedef = Enum.find(entities, &(&1.name == "ID"))

      assert typedef != nil
      assert typedef.entity_type == :struct
      assert typedef.contains == []
    end

    test "multiple type specs in one declaration" do
      ast =
        wrap_program([
          make_node("type_declaration",
            children: [
              make_node("type_spec",
                start_row: 1,
                end_row: 3,
                children: [
                  make_node("type_identifier", text: "Request"),
                  make_node("struct_type",
                    children: [
                      make_node("field_declaration",
                        children: [
                          make_node("field_identifier", text: "URL")
                        ]
                      )
                    ]
                  )
                ]
              ),
              make_node("type_spec",
                start_row: 4,
                end_row: 6,
                children: [
                  make_node("type_identifier", text: "Response"),
                  make_node("struct_type",
                    children: [
                      make_node("field_declaration",
                        children: [
                          make_node("field_identifier", text: "Body")
                        ]
                      )
                    ]
                  )
                ]
              )
            ]
          )
        ])

      source = "type (\n  Request struct {\n    URL string\n  }\n  Response struct {\n    Body []byte\n  }\n)"
      entities = GoExtractor.extract_entities("http.go", ast, source)

      req = Enum.find(entities, &(&1.name == "Request"))
      resp = Enum.find(entities, &(&1.name == "Response"))

      assert req != nil
      assert resp != nil
      assert "URL" in req.contains
      assert "Body" in resp.contains
    end
  end

  describe "import declarations" do
    test "extracts single import" do
      ast =
        wrap_program([
          make_node("import_declaration",
            children: [
              make_node("import_spec",
                children: [
                  make_node("interpreted_string_literal", text: "\"fmt\"")
                ]
              )
            ]
          )
        ])

      imports = GoExtractor.extract_imports(ast)
      assert "fmt" in imports
    end

    test "extracts grouped imports" do
      ast =
        wrap_program([
          make_node("import_declaration",
            children: [
              make_node("import_spec_list",
                children: [
                  make_node("import_spec",
                    children: [
                      make_node("interpreted_string_literal", text: "\"fmt\"")
                    ]
                  ),
                  make_node("import_spec",
                    children: [
                      make_node("interpreted_string_literal", text: "\"net/http\"")
                    ]
                  ),
                  make_node("import_spec",
                    children: [
                      make_node("interpreted_string_literal", text: "\"github.com/user/pkg\"")
                    ]
                  )
                ]
              )
            ]
          )
        ])

      imports = GoExtractor.extract_imports(ast)
      assert "fmt" in imports
      assert "net/http" in imports
      assert "github.com/user/pkg" in imports
    end

    test "imports are added to all entity is_a lists" do
      ast =
        wrap_program([
          make_node("package_clause",
            children: [
              make_node("package_identifier", text: "main")
            ]
          ),
          make_node("import_declaration",
            children: [
              make_node("import_spec_list",
                children: [
                  make_node("import_spec",
                    children: [
                      make_node("interpreted_string_literal", text: "\"fmt\"")
                    ]
                  )
                ]
              )
            ]
          ),
          make_node("function_declaration",
            start_row: 4,
            end_row: 6,
            children: [
              make_node("identifier", text: "Run"),
              make_node("parameter_list", children: []),
              make_node("block", children: [])
            ]
          )
        ])

      entities = GoExtractor.extract_entities("main.go", ast, "package main\n\nimport \"fmt\"\n\nfunc Run() {\n}")
      func = Enum.find(entities, &(&1.name == "Run" && &1.entity_type == :function))

      assert func != nil
      assert "fmt" in func.is_a
    end

    test "imports are deduplicated" do
      ast =
        wrap_program([
          make_node("import_declaration",
            children: [
              make_node("import_spec",
                children: [
                  make_node("interpreted_string_literal", text: "\"fmt\"")
                ]
              )
            ]
          ),
          make_node("import_declaration",
            children: [
              make_node("import_spec",
                children: [
                  make_node("interpreted_string_literal", text: "\"fmt\"")
                ]
              )
            ]
          )
        ])

      imports = GoExtractor.extract_imports(ast)
      assert Enum.count(imports, &(&1 == "fmt")) == 1
    end
  end

  describe "package clause" do
    test "extracts package name for module entity" do
      ast =
        wrap_program([
          make_node("package_clause",
            children: [
              make_node("package_identifier", text: "main")
            ]
          )
        ])

      entities = GoExtractor.extract_entities("main.go", ast, "package main")
      mod = Enum.find(entities, &(&1.entity_type == :module))

      assert mod != nil
      assert mod.name == "main"
      assert mod.language == :go
    end

    test "module entity without package uses filename" do
      ast =
        wrap_program([
          make_node("import_declaration",
            children: [
              make_node("import_spec",
                children: [
                  make_node("interpreted_string_literal", text: "\"fmt\"")
                ]
              )
            ]
          )
        ])

      entities = GoExtractor.extract_entities("utils.go", ast, "import \"fmt\"")
      mod = Enum.find(entities, &(&1.entity_type == :module))

      assert mod != nil
      assert mod.name == "utils"
    end

    test "module entity contains only exported names" do
      ast =
        wrap_program([
          make_node("package_clause",
            children: [
              make_node("package_identifier", text: "parser")
            ]
          ),
          make_node("function_declaration",
            start_row: 2,
            end_row: 3,
            children: [
              make_node("identifier", text: "Parse"),
              make_node("parameter_list", children: []),
              make_node("block", children: [])
            ]
          ),
          make_node("function_declaration",
            start_row: 5,
            end_row: 6,
            children: [
              make_node("identifier", text: "helper"),
              make_node("parameter_list", children: []),
              make_node("block", children: [])
            ]
          )
        ])

      source = "package parser\n\nfunc Parse() {}\n\nfunc helper() {}"
      entities = GoExtractor.extract_entities("parser.go", ast, source)
      mod = Enum.find(entities, &(&1.entity_type == :module))

      assert mod != nil
      assert "Parse" in mod.contains
      refute "helper" in mod.contains
    end

    test "module entity calls list contains imported package short names" do
      ast =
        wrap_program([
          make_node("package_clause",
            children: [
              make_node("package_identifier", text: "main")
            ]
          ),
          make_node("import_declaration",
            children: [
              make_node("import_spec_list",
                children: [
                  make_node("import_spec",
                    children: [
                      make_node("interpreted_string_literal", text: "\"fmt\"")
                    ]
                  ),
                  make_node("import_spec",
                    children: [
                      make_node("interpreted_string_literal", text: "\"net/http\"")
                    ]
                  ),
                  make_node("import_spec",
                    children: [
                      make_node("interpreted_string_literal", text: "\"github.com/gorilla/mux\"")
                    ]
                  )
                ]
              )
            ]
          )
        ])

      entities =
        GoExtractor.extract_entities(
          "main.go",
          ast,
          "package main\nimport (\n  \"fmt\"\n  \"net/http\"\n  \"github.com/gorilla/mux\"\n)"
        )

      mod = Enum.find(entities, &(&1.entity_type == :module))

      assert mod != nil
      assert "fmt" in mod.calls
      assert "http" in mod.calls
      assert "mux" in mod.calls
    end
  end
end
