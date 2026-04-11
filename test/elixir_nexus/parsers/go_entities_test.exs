defmodule ElixirNexus.Parsers.GoEntitiesTest do
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

  describe "function declarations" do
    test "extracts a simple function declaration" do
      ast =
        wrap_program([
          make_node("function_declaration",
            start_row: 0,
            end_row: 2,
            children: [
              make_node("identifier", text: "ParseProgram"),
              make_node("parameter_list",
                children: [
                  make_node("parameter_declaration",
                    children: [
                      make_node("identifier", text: "input")
                    ]
                  )
                ]
              ),
              make_node("block", children: [])
            ]
          )
        ])

      source = "func ParseProgram(input string) {\n  // body\n}"
      entities = GoExtractor.extract_entities("parser.go", ast, source)
      func = Enum.find(entities, &(&1.name == "ParseProgram" && &1.entity_type == :function))

      assert func != nil
      assert func.entity_type == :function
      assert func.start_line == 1
      assert func.end_line == 3
      assert "input" in func.parameters
      assert func.language == :go
    end

    test "extracts function name from name field" do
      ast =
        wrap_program([
          make_node("function_declaration",
            name: "main",
            start_row: 0,
            end_row: 2,
            children: [
              make_node("parameter_list", children: []),
              make_node("block", children: [])
            ]
          )
        ])

      source = "func main() {\n}"
      entities = GoExtractor.extract_entities("main.go", ast, source)
      func = Enum.find(entities, &(&1.name == "main" && &1.entity_type == :function))

      assert func != nil
      assert func.entity_type == :function
    end

    test "exported function has public visibility" do
      ast =
        wrap_program([
          make_node("function_declaration",
            start_row: 0,
            end_row: 0,
            children: [
              make_node("identifier", text: "HandleRequest"),
              make_node("parameter_list", children: []),
              make_node("block", children: [])
            ]
          )
        ])

      entities = GoExtractor.extract_entities("handler.go", ast, "func HandleRequest() {}")
      func = Enum.find(entities, &(&1.name == "HandleRequest"))

      assert func.visibility == :public
    end

    test "unexported function has private visibility" do
      ast =
        wrap_program([
          make_node("function_declaration",
            start_row: 0,
            end_row: 0,
            children: [
              make_node("identifier", text: "helperFunc"),
              make_node("parameter_list", children: []),
              make_node("block", children: [])
            ]
          )
        ])

      entities = GoExtractor.extract_entities("helper.go", ast, "func helperFunc() {}")
      func = Enum.find(entities, &(&1.name == "helperFunc"))

      assert func.visibility == :private
    end

    test "extracts multiple parameters" do
      ast =
        wrap_program([
          make_node("function_declaration",
            start_row: 0,
            end_row: 0,
            children: [
              make_node("identifier", text: "Add"),
              make_node("parameter_list",
                children: [
                  make_node("parameter_declaration",
                    children: [
                      make_node("identifier", text: "a")
                    ]
                  ),
                  make_node("parameter_declaration",
                    children: [
                      make_node("identifier", text: "b")
                    ]
                  )
                ]
              ),
              make_node("block", children: [])
            ]
          )
        ])

      entities = GoExtractor.extract_entities("math.go", ast, "func Add(a int, b int) int {}")
      func = Enum.find(entities, &(&1.name == "Add"))

      assert "a" in func.parameters
      assert "b" in func.parameters
    end
  end

  describe "method declarations" do
    test "extracts method with pointer receiver" do
      ast =
        wrap_program([
          make_node("method_declaration",
            start_row: 0,
            end_row: 5,
            children: [
              make_node("parameter_list",
                children: [
                  make_node("parameter_declaration",
                    children: [
                      make_node("identifier", text: "p"),
                      make_node("pointer_type",
                        children: [
                          make_node("type_identifier", text: "Parser")
                        ]
                      )
                    ]
                  )
                ]
              ),
              make_node("field_identifier", text: "parseExpression"),
              make_node("parameter_list", children: []),
              make_node("block", children: [])
            ]
          )
        ])

      source = "func (p *Parser) parseExpression() {\n  // body\n}"
      entities = GoExtractor.extract_entities("parser.go", ast, source)
      method = Enum.find(entities, &(&1.entity_type == :method))

      assert method != nil
      assert method.name == "Parser.parseExpression"
      assert method.entity_type == :method
      assert method.visibility == :private
    end

    test "extracts method with value receiver" do
      ast =
        wrap_program([
          make_node("method_declaration",
            start_row: 0,
            end_row: 3,
            children: [
              make_node("parameter_list",
                children: [
                  make_node("parameter_declaration",
                    children: [
                      make_node("identifier", text: "s"),
                      make_node("type_identifier", text: "Server")
                    ]
                  )
                ]
              ),
              make_node("field_identifier", text: "Start"),
              make_node("parameter_list", children: []),
              make_node("block", children: [])
            ]
          )
        ])

      entities = GoExtractor.extract_entities("server.go", ast, "func (s Server) Start() {}")
      method = Enum.find(entities, &(&1.entity_type == :method))

      assert method != nil
      assert method.name == "Server.Start"
      assert method.visibility == :public
    end

    test "method parameters exclude receiver" do
      ast =
        wrap_program([
          make_node("method_declaration",
            start_row: 0,
            end_row: 3,
            children: [
              make_node("parameter_list",
                children: [
                  make_node("parameter_declaration",
                    children: [
                      make_node("identifier", text: "s"),
                      make_node("pointer_type",
                        children: [
                          make_node("type_identifier", text: "Server")
                        ]
                      )
                    ]
                  )
                ]
              ),
              make_node("field_identifier", text: "Listen"),
              make_node("parameter_list",
                children: [
                  make_node("parameter_declaration",
                    children: [
                      make_node("identifier", text: "port")
                    ]
                  )
                ]
              ),
              make_node("block", children: [])
            ]
          )
        ])

      entities = GoExtractor.extract_entities("server.go", ast, "func (s *Server) Listen(port int) {}")
      method = Enum.find(entities, &(&1.name == "Server.Listen"))

      assert method != nil
      assert "port" in method.parameters
      # The receiver parameter "s" should not be in the params list
      refute "s" in method.parameters
    end

    test "exported method on exported type has public visibility" do
      ast =
        wrap_program([
          make_node("method_declaration",
            start_row: 0,
            end_row: 0,
            children: [
              make_node("parameter_list",
                children: [
                  make_node("parameter_declaration",
                    children: [
                      make_node("identifier", text: "h"),
                      make_node("pointer_type",
                        children: [
                          make_node("type_identifier", text: "Handler")
                        ]
                      )
                    ]
                  )
                ]
              ),
              make_node("field_identifier", text: "ServeHTTP"),
              make_node("parameter_list", children: []),
              make_node("block", children: [])
            ]
          )
        ])

      entities = GoExtractor.extract_entities("handler.go", ast, "func (h *Handler) ServeHTTP() {}")
      method = Enum.find(entities, &(&1.name == "Handler.ServeHTTP"))

      assert method.visibility == :public
    end
  end

  describe "content extraction" do
    test "entity content matches source lines" do
      ast =
        wrap_program([
          make_node("function_declaration",
            start_row: 0,
            end_row: 2,
            children: [
              make_node("identifier", text: "Hello"),
              make_node("parameter_list", children: []),
              make_node("block", children: [])
            ]
          )
        ])

      source = "func Hello() {\n  return\n}"
      entities = GoExtractor.extract_entities("greet.go", ast, source)
      func = Enum.find(entities, &(&1.name == "Hello"))

      assert func.content == "func Hello() {\n  return\n}"
    end
  end

  describe "edge cases" do
    test "function declaration without children is handled" do
      ast =
        wrap_program([
          %{
            "kind" => "function_declaration",
            "name" => "bare",
            "start_row" => 0,
            "end_row" => 0,
            "start_col" => 0,
            "end_col" => 0,
            "text" => ""
          }
        ])

      entities = GoExtractor.extract_entities("test.go", ast, "func bare() {}")
      func = Enum.find(entities, &(&1.name == "bare"))

      assert func != nil
      assert func.entity_type == :function
    end

    test "method declaration without children returns nil receiver" do
      ast =
        wrap_program([
          %{
            "kind" => "method_declaration",
            "start_row" => 0,
            "end_row" => 0,
            "start_col" => 0,
            "end_col" => 0,
            "text" => ""
          }
        ])

      # Should not crash
      entities = GoExtractor.extract_entities("test.go", ast, "")
      assert is_list(entities)
    end

    test "empty source file produces no entities" do
      ast = wrap_program([])
      entities = GoExtractor.extract_entities("empty.go", ast, "")

      assert entities == []
    end

    test "call_expression without children is handled" do
      ast =
        wrap_program([
          make_node("function_declaration",
            start_row: 0,
            end_row: 1,
            children: [
              make_node("identifier", text: "test"),
              make_node("parameter_list", children: []),
              make_node("block",
                children: [
                  make_node("expression_statement",
                    children: [
                      %{
                        "kind" => "call_expression",
                        "start_row" => 0,
                        "end_row" => 0,
                        "start_col" => 0,
                        "end_col" => 0,
                        "text" => ""
                      }
                    ]
                  )
                ]
              )
            ]
          )
        ])

      entities = GoExtractor.extract_entities("test.go", ast, "func test() {\n}")
      func = Enum.find(entities, &(&1.name == "test"))
      assert func != nil
      assert func.calls == []
    end

    test "selector_expression with text fallback" do
      ast =
        wrap_program([
          make_node("function_declaration",
            start_row: 0,
            end_row: 1,
            children: [
              make_node("identifier", text: "test"),
              make_node("parameter_list", children: []),
              make_node("block",
                children: [
                  make_node("expression_statement",
                    children: [
                      make_node("call_expression",
                        children: [
                          %{
                            "kind" => "selector_expression",
                            "text" => "os.Exit",
                            "start_row" => 0,
                            "end_row" => 0,
                            "start_col" => 0,
                            "end_col" => 0
                          },
                          make_node("argument_list", children: [])
                        ]
                      )
                    ]
                  )
                ]
              )
            ]
          )
        ])

      entities = GoExtractor.extract_entities("test.go", ast, "func test() {\n  os.Exit(1)\n}")
      func = Enum.find(entities, &(&1.name == "test"))

      assert "os.Exit" in func.calls
    end
  end

  describe "file-level module entity" do
    test "no module entity when no package or imports" do
      ast =
        wrap_program([
          make_node("function_declaration",
            start_row: 0,
            end_row: 0,
            children: [
              make_node("identifier", text: "solo"),
              make_node("parameter_list", children: []),
              make_node("block", children: [])
            ]
          )
        ])

      entities = GoExtractor.extract_entities("test.go", ast, "func solo() {}")
      mod = Enum.find(entities, &(&1.entity_type == :module))

      assert mod == nil
    end

    test "module entity is_a contains imports" do
      ast =
        wrap_program([
          make_node("package_clause",
            children: [
              make_node("package_identifier", text: "app")
            ]
          ),
          make_node("import_declaration",
            children: [
              make_node("import_spec_list",
                children: [
                  make_node("import_spec",
                    children: [
                      make_node("interpreted_string_literal", text: "\"os\"")
                    ]
                  )
                ]
              )
            ]
          )
        ])

      entities = GoExtractor.extract_entities("app.go", ast, "package app\nimport \"os\"")
      mod = Enum.find(entities, &(&1.entity_type == :module))

      assert mod != nil
      assert "os" in mod.is_a
    end
  end

  describe "complete Go file" do
    test "extracts all entities from a realistic Go file" do
      ast =
        wrap_program([
          make_node("package_clause",
            children: [
              make_node("package_identifier", text: "server")
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
                  )
                ]
              )
            ]
          ),
          make_node("type_declaration",
            children: [
              make_node("type_spec",
                start_row: 7,
                end_row: 10,
                children: [
                  make_node("type_identifier", text: "App"),
                  make_node("struct_type",
                    children: [
                      make_node("field_declaration",
                        children: [
                          make_node("field_identifier", text: "Name")
                        ]
                      )
                    ]
                  )
                ]
              )
            ]
          ),
          make_node("method_declaration",
            start_row: 12,
            end_row: 15,
            children: [
              make_node("parameter_list",
                children: [
                  make_node("parameter_declaration",
                    children: [
                      make_node("identifier", text: "a"),
                      make_node("pointer_type",
                        children: [
                          make_node("type_identifier", text: "App")
                        ]
                      )
                    ]
                  )
                ]
              ),
              make_node("field_identifier", text: "Run"),
              make_node("parameter_list",
                children: [
                  make_node("parameter_declaration",
                    children: [
                      make_node("identifier", text: "addr")
                    ]
                  )
                ]
              ),
              make_node("block",
                children: [
                  make_node("expression_statement",
                    children: [
                      make_node("call_expression",
                        children: [
                          make_node("selector_expression",
                            children: [
                              make_node("identifier", text: "fmt"),
                              make_node("field_identifier", text: "Println")
                            ]
                          ),
                          make_node("argument_list", children: [])
                        ]
                      )
                    ]
                  )
                ]
              )
            ]
          ),
          make_node("function_declaration",
            start_row: 17,
            end_row: 19,
            children: [
              make_node("identifier", text: "main"),
              make_node("parameter_list", children: []),
              make_node("block", children: [])
            ]
          )
        ])

      source =
        Enum.join(
          [
            "package server",
            "",
            "import (",
            "  \"fmt\"",
            "  \"net/http\"",
            ")",
            "",
            "type App struct {",
            "  Name string",
            "}",
            "",
            "",
            "func (a *App) Run(addr string) {",
            "  fmt.Println(addr)",
            "}",
            "",
            "",
            "func main() {",
            "}",
            ""
          ],
          "\n"
        )

      entities = GoExtractor.extract_entities("main.go", ast, source)

      # Module entity
      mod = Enum.find(entities, &(&1.entity_type == :module))
      assert mod != nil
      assert mod.name == "server"
      assert "fmt" in mod.is_a
      assert "net/http" in mod.is_a
      assert "App.Run" in mod.contains

      # Struct
      app = Enum.find(entities, &(&1.name == "App" && &1.entity_type == :struct))
      assert app != nil
      assert "Name" in app.contains
      assert "fmt" in app.is_a

      # Method
      run = Enum.find(entities, &(&1.name == "App.Run" && &1.entity_type == :method))
      assert run != nil
      assert run.visibility == :public
      assert "addr" in run.parameters
      assert "fmt.Println" in run.calls

      # Function
      main = Enum.find(entities, &(&1.name == "main" && &1.entity_type == :function))
      assert main != nil
      assert main.visibility == :private
    end
  end
end
