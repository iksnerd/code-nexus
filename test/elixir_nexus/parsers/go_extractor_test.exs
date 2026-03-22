defmodule ElixirNexus.Parsers.GoExtractorTest do
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
      ast = wrap_program([
        make_node("function_declaration", start_row: 0, end_row: 2, children: [
          make_node("identifier", text: "ParseProgram"),
          make_node("parameter_list", children: [
            make_node("parameter_declaration", children: [
              make_node("identifier", text: "input")
            ])
          ]),
          make_node("block", children: [])
        ])
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
      ast = wrap_program([
        make_node("function_declaration", name: "main", start_row: 0, end_row: 2, children: [
          make_node("parameter_list", children: []),
          make_node("block", children: [])
        ])
      ])

      source = "func main() {\n}"
      entities = GoExtractor.extract_entities("main.go", ast, source)
      func = Enum.find(entities, &(&1.name == "main" && &1.entity_type == :function))

      assert func != nil
      assert func.entity_type == :function
    end

    test "exported function has public visibility" do
      ast = wrap_program([
        make_node("function_declaration", start_row: 0, end_row: 0, children: [
          make_node("identifier", text: "HandleRequest"),
          make_node("parameter_list", children: []),
          make_node("block", children: [])
        ])
      ])

      entities = GoExtractor.extract_entities("handler.go", ast, "func HandleRequest() {}")
      func = Enum.find(entities, &(&1.name == "HandleRequest"))

      assert func.visibility == :public
    end

    test "unexported function has private visibility" do
      ast = wrap_program([
        make_node("function_declaration", start_row: 0, end_row: 0, children: [
          make_node("identifier", text: "helperFunc"),
          make_node("parameter_list", children: []),
          make_node("block", children: [])
        ])
      ])

      entities = GoExtractor.extract_entities("helper.go", ast, "func helperFunc() {}")
      func = Enum.find(entities, &(&1.name == "helperFunc"))

      assert func.visibility == :private
    end

    test "extracts multiple parameters" do
      ast = wrap_program([
        make_node("function_declaration", start_row: 0, end_row: 0, children: [
          make_node("identifier", text: "Add"),
          make_node("parameter_list", children: [
            make_node("parameter_declaration", children: [
              make_node("identifier", text: "a")
            ]),
            make_node("parameter_declaration", children: [
              make_node("identifier", text: "b")
            ])
          ]),
          make_node("block", children: [])
        ])
      ])

      entities = GoExtractor.extract_entities("math.go", ast, "func Add(a int, b int) int {}")
      func = Enum.find(entities, &(&1.name == "Add"))

      assert "a" in func.parameters
      assert "b" in func.parameters
    end
  end

  describe "method declarations" do
    test "extracts method with pointer receiver" do
      ast = wrap_program([
        make_node("method_declaration", start_row: 0, end_row: 5, children: [
          make_node("parameter_list", children: [
            make_node("parameter_declaration", children: [
              make_node("identifier", text: "p"),
              make_node("pointer_type", children: [
                make_node("type_identifier", text: "Parser")
              ])
            ])
          ]),
          make_node("field_identifier", text: "parseExpression"),
          make_node("parameter_list", children: []),
          make_node("block", children: [])
        ])
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
      ast = wrap_program([
        make_node("method_declaration", start_row: 0, end_row: 3, children: [
          make_node("parameter_list", children: [
            make_node("parameter_declaration", children: [
              make_node("identifier", text: "s"),
              make_node("type_identifier", text: "Server")
            ])
          ]),
          make_node("field_identifier", text: "Start"),
          make_node("parameter_list", children: []),
          make_node("block", children: [])
        ])
      ])

      entities = GoExtractor.extract_entities("server.go", ast, "func (s Server) Start() {}")
      method = Enum.find(entities, &(&1.entity_type == :method))

      assert method != nil
      assert method.name == "Server.Start"
      assert method.visibility == :public
    end

    test "method parameters exclude receiver" do
      ast = wrap_program([
        make_node("method_declaration", start_row: 0, end_row: 3, children: [
          make_node("parameter_list", children: [
            make_node("parameter_declaration", children: [
              make_node("identifier", text: "s"),
              make_node("pointer_type", children: [
                make_node("type_identifier", text: "Server")
              ])
            ])
          ]),
          make_node("field_identifier", text: "Listen"),
          make_node("parameter_list", children: [
            make_node("parameter_declaration", children: [
              make_node("identifier", text: "port")
            ])
          ]),
          make_node("block", children: [])
        ])
      ])

      entities = GoExtractor.extract_entities("server.go", ast, "func (s *Server) Listen(port int) {}")
      method = Enum.find(entities, &(&1.name == "Server.Listen"))

      assert method != nil
      assert "port" in method.parameters
      # The receiver parameter "s" should not be in the params list
      refute "s" in method.parameters
    end

    test "exported method on exported type has public visibility" do
      ast = wrap_program([
        make_node("method_declaration", start_row: 0, end_row: 0, children: [
          make_node("parameter_list", children: [
            make_node("parameter_declaration", children: [
              make_node("identifier", text: "h"),
              make_node("pointer_type", children: [
                make_node("type_identifier", text: "Handler")
              ])
            ])
          ]),
          make_node("field_identifier", text: "ServeHTTP"),
          make_node("parameter_list", children: []),
          make_node("block", children: [])
        ])
      ])

      entities = GoExtractor.extract_entities("handler.go", ast, "func (h *Handler) ServeHTTP() {}")
      method = Enum.find(entities, &(&1.name == "Handler.ServeHTTP"))

      assert method.visibility == :public
    end
  end

  describe "call expressions" do
    test "extracts direct function call" do
      ast = wrap_program([
        make_node("function_declaration", start_row: 0, end_row: 2, children: [
          make_node("identifier", text: "main"),
          make_node("parameter_list", children: []),
          make_node("block", children: [
            make_node("expression_statement", children: [
              make_node("call_expression", children: [
                make_node("identifier", text: "foo"),
                make_node("argument_list", children: [])
              ])
            ])
          ])
        ])
      ])

      entities = GoExtractor.extract_entities("main.go", ast, "func main() {\n  foo()\n}")
      func = Enum.find(entities, &(&1.name == "main"))

      assert "foo" in func.calls
    end

    test "extracts package-qualified call" do
      ast = wrap_program([
        make_node("function_declaration", start_row: 0, end_row: 2, children: [
          make_node("identifier", text: "main"),
          make_node("parameter_list", children: []),
          make_node("block", children: [
            make_node("expression_statement", children: [
              make_node("call_expression", children: [
                make_node("selector_expression", children: [
                  make_node("identifier", text: "fmt"),
                  make_node("field_identifier", text: "Println")
                ]),
                make_node("argument_list", children: [])
              ])
            ])
          ])
        ])
      ])

      entities = GoExtractor.extract_entities("main.go", ast, "func main() {\n  fmt.Println()\n}")
      func = Enum.find(entities, &(&1.name == "main"))

      assert "fmt.Println" in func.calls
    end

    test "extracts multiple calls" do
      ast = wrap_program([
        make_node("function_declaration", start_row: 0, end_row: 4, children: [
          make_node("identifier", text: "run"),
          make_node("parameter_list", children: []),
          make_node("block", children: [
            make_node("expression_statement", children: [
              make_node("call_expression", children: [
                make_node("identifier", text: "setup"),
                make_node("argument_list", children: [])
              ])
            ]),
            make_node("expression_statement", children: [
              make_node("call_expression", children: [
                make_node("selector_expression", children: [
                  make_node("identifier", text: "log"),
                  make_node("field_identifier", text: "Info")
                ]),
                make_node("argument_list", children: [])
              ])
            ])
          ])
        ])
      ])

      entities = GoExtractor.extract_entities("app.go", ast, "func run() {\n  setup()\n  log.Info()\n}")
      func = Enum.find(entities, &(&1.name == "run"))

      assert "setup" in func.calls
      assert "log.Info" in func.calls
    end

    test "extracts nested calls in arguments" do
      ast = wrap_program([
        make_node("function_declaration", start_row: 0, end_row: 2, children: [
          make_node("identifier", text: "main"),
          make_node("parameter_list", children: []),
          make_node("block", children: [
            make_node("expression_statement", children: [
              make_node("call_expression", children: [
                make_node("selector_expression", children: [
                  make_node("identifier", text: "fmt"),
                  make_node("field_identifier", text: "Println")
                ]),
                make_node("argument_list", children: [
                  make_node("call_expression", children: [
                    make_node("identifier", text: "getMessage"),
                    make_node("argument_list", children: [])
                  ])
                ])
              ])
            ])
          ])
        ])
      ])

      entities = GoExtractor.extract_entities("main.go", ast, "func main() {\n  fmt.Println(getMessage())\n}")
      func = Enum.find(entities, &(&1.name == "main"))

      assert "fmt.Println" in func.calls
      assert "getMessage" in func.calls
    end

    test "calls are deduplicated" do
      ast = wrap_program([
        make_node("function_declaration", start_row: 0, end_row: 3, children: [
          make_node("identifier", text: "process"),
          make_node("parameter_list", children: []),
          make_node("block", children: [
            make_node("expression_statement", children: [
              make_node("call_expression", children: [
                make_node("identifier", text: "validate"),
                make_node("argument_list", children: [])
              ])
            ]),
            make_node("expression_statement", children: [
              make_node("call_expression", children: [
                make_node("identifier", text: "validate"),
                make_node("argument_list", children: [])
              ])
            ])
          ])
        ])
      ])

      entities = GoExtractor.extract_entities("proc.go", ast, "func process() {\n  validate()\n  validate()\n}")
      func = Enum.find(entities, &(&1.name == "process"))

      call_counts = Enum.frequencies(func.calls)
      assert Map.get(call_counts, "validate") == 1
    end
  end

  describe "import declarations" do
    test "extracts single import" do
      ast = wrap_program([
        make_node("import_declaration", children: [
          make_node("import_spec", children: [
            make_node("interpreted_string_literal", text: "\"fmt\"")
          ])
        ])
      ])

      imports = GoExtractor.extract_imports(ast)
      assert "fmt" in imports
    end

    test "extracts grouped imports" do
      ast = wrap_program([
        make_node("import_declaration", children: [
          make_node("import_spec_list", children: [
            make_node("import_spec", children: [
              make_node("interpreted_string_literal", text: "\"fmt\"")
            ]),
            make_node("import_spec", children: [
              make_node("interpreted_string_literal", text: "\"net/http\"")
            ]),
            make_node("import_spec", children: [
              make_node("interpreted_string_literal", text: "\"github.com/user/pkg\"")
            ])
          ])
        ])
      ])

      imports = GoExtractor.extract_imports(ast)
      assert "fmt" in imports
      assert "net/http" in imports
      assert "github.com/user/pkg" in imports
    end

    test "imports are added to all entity is_a lists" do
      ast = wrap_program([
        make_node("package_clause", children: [
          make_node("package_identifier", text: "main")
        ]),
        make_node("import_declaration", children: [
          make_node("import_spec_list", children: [
            make_node("import_spec", children: [
              make_node("interpreted_string_literal", text: "\"fmt\"")
            ])
          ])
        ]),
        make_node("function_declaration", start_row: 4, end_row: 6, children: [
          make_node("identifier", text: "Run"),
          make_node("parameter_list", children: []),
          make_node("block", children: [])
        ])
      ])

      entities = GoExtractor.extract_entities("main.go", ast, "package main\n\nimport \"fmt\"\n\nfunc Run() {\n}")
      func = Enum.find(entities, &(&1.name == "Run" && &1.entity_type == :function))

      assert func != nil
      assert "fmt" in func.is_a
    end

    test "imports are deduplicated" do
      ast = wrap_program([
        make_node("import_declaration", children: [
          make_node("import_spec", children: [
            make_node("interpreted_string_literal", text: "\"fmt\"")
          ])
        ]),
        make_node("import_declaration", children: [
          make_node("import_spec", children: [
            make_node("interpreted_string_literal", text: "\"fmt\"")
          ])
        ])
      ])

      imports = GoExtractor.extract_imports(ast)
      assert Enum.count(imports, &(&1 == "fmt")) == 1
    end
  end

  describe "type declarations" do
    test "extracts struct type with fields" do
      ast = wrap_program([
        make_node("type_declaration", children: [
          make_node("type_spec", start_row: 0, end_row: 4, children: [
            make_node("type_identifier", text: "Server"),
            make_node("struct_type", children: [
              make_node("field_declaration", children: [
                make_node("field_identifier", text: "Host")
              ]),
              make_node("field_declaration", children: [
                make_node("field_identifier", text: "Port")
              ])
            ])
          ])
        ])
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
      ast = wrap_program([
        make_node("type_declaration", children: [
          make_node("type_spec", start_row: 0, end_row: 3, children: [
            make_node("type_identifier", text: "Reader"),
            make_node("interface_type", children: [
              make_node("method_spec", children: [
                make_node("field_identifier", text: "Read")
              ]),
              make_node("method_spec", children: [
                make_node("field_identifier", text: "Close")
              ])
            ])
          ])
        ])
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
      ast = wrap_program([
        make_node("type_declaration", children: [
          make_node("type_spec", start_row: 0, end_row: 2, children: [
            make_node("type_identifier", text: "config"),
            make_node("struct_type", children: [])
          ])
        ])
      ])

      entities = GoExtractor.extract_entities("config.go", ast, "type config struct {}")
      struct = Enum.find(entities, &(&1.name == "config"))

      assert struct != nil
      assert struct.visibility == :private
    end

    test "type spec without struct or interface defaults to struct" do
      ast = wrap_program([
        make_node("type_declaration", children: [
          make_node("type_spec", start_row: 0, end_row: 0, children: [
            make_node("type_identifier", text: "ID"),
            make_node("primitive_type", text: "int64")
          ])
        ])
      ])

      entities = GoExtractor.extract_entities("types.go", ast, "type ID int64")
      typedef = Enum.find(entities, &(&1.name == "ID"))

      assert typedef != nil
      assert typedef.entity_type == :struct
      assert typedef.contains == []
    end

    test "multiple type specs in one declaration" do
      ast = wrap_program([
        make_node("type_declaration", children: [
          make_node("type_spec", start_row: 1, end_row: 3, children: [
            make_node("type_identifier", text: "Request"),
            make_node("struct_type", children: [
              make_node("field_declaration", children: [
                make_node("field_identifier", text: "URL")
              ])
            ])
          ]),
          make_node("type_spec", start_row: 4, end_row: 6, children: [
            make_node("type_identifier", text: "Response"),
            make_node("struct_type", children: [
              make_node("field_declaration", children: [
                make_node("field_identifier", text: "Body")
              ])
            ])
          ])
        ])
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

  describe "package clause" do
    test "extracts package name for module entity" do
      ast = wrap_program([
        make_node("package_clause", children: [
          make_node("package_identifier", text: "main")
        ])
      ])

      entities = GoExtractor.extract_entities("main.go", ast, "package main")
      mod = Enum.find(entities, &(&1.entity_type == :module))

      assert mod != nil
      assert mod.name == "main"
      assert mod.language == :go
    end

    test "module entity without package uses filename" do
      ast = wrap_program([
        make_node("import_declaration", children: [
          make_node("import_spec", children: [
            make_node("interpreted_string_literal", text: "\"fmt\"")
          ])
        ])
      ])

      entities = GoExtractor.extract_entities("utils.go", ast, "import \"fmt\"")
      mod = Enum.find(entities, &(&1.entity_type == :module))

      assert mod != nil
      assert mod.name == "utils"
    end

    test "module entity contains only exported names" do
      ast = wrap_program([
        make_node("package_clause", children: [
          make_node("package_identifier", text: "parser")
        ]),
        make_node("function_declaration", start_row: 2, end_row: 3, children: [
          make_node("identifier", text: "Parse"),
          make_node("parameter_list", children: []),
          make_node("block", children: [])
        ]),
        make_node("function_declaration", start_row: 5, end_row: 6, children: [
          make_node("identifier", text: "helper"),
          make_node("parameter_list", children: []),
          make_node("block", children: [])
        ])
      ])

      source = "package parser\n\nfunc Parse() {}\n\nfunc helper() {}"
      entities = GoExtractor.extract_entities("parser.go", ast, source)
      mod = Enum.find(entities, &(&1.entity_type == :module))

      assert mod != nil
      assert "Parse" in mod.contains
      refute "helper" in mod.contains
    end

    test "module entity calls list contains imported package short names" do
      ast = wrap_program([
        make_node("package_clause", children: [
          make_node("package_identifier", text: "main")
        ]),
        make_node("import_declaration", children: [
          make_node("import_spec_list", children: [
            make_node("import_spec", children: [
              make_node("interpreted_string_literal", text: "\"fmt\"")
            ]),
            make_node("import_spec", children: [
              make_node("interpreted_string_literal", text: "\"net/http\"")
            ]),
            make_node("import_spec", children: [
              make_node("interpreted_string_literal", text: "\"github.com/gorilla/mux\"")
            ])
          ])
        ])
      ])

      entities = GoExtractor.extract_entities("main.go", ast, "package main\nimport (\n  \"fmt\"\n  \"net/http\"\n  \"github.com/gorilla/mux\"\n)")
      mod = Enum.find(entities, &(&1.entity_type == :module))

      assert mod != nil
      assert "fmt" in mod.calls
      assert "http" in mod.calls
      assert "mux" in mod.calls
    end
  end

  describe "file-level module entity" do
    test "no module entity when no package or imports" do
      ast = wrap_program([
        make_node("function_declaration", start_row: 0, end_row: 0, children: [
          make_node("identifier", text: "solo"),
          make_node("parameter_list", children: []),
          make_node("block", children: [])
        ])
      ])

      entities = GoExtractor.extract_entities("test.go", ast, "func solo() {}")
      mod = Enum.find(entities, &(&1.entity_type == :module))

      assert mod == nil
    end

    test "module entity is_a contains imports" do
      ast = wrap_program([
        make_node("package_clause", children: [
          make_node("package_identifier", text: "app")
        ]),
        make_node("import_declaration", children: [
          make_node("import_spec_list", children: [
            make_node("import_spec", children: [
              make_node("interpreted_string_literal", text: "\"os\"")
            ])
          ])
        ])
      ])

      entities = GoExtractor.extract_entities("app.go", ast, "package app\nimport \"os\"")
      mod = Enum.find(entities, &(&1.entity_type == :module))

      assert mod != nil
      assert "os" in mod.is_a
    end
  end

  describe "chained calls" do
    test "extracts chained method calls" do
      # Simulates: builder.SetName("x").Build()
      inner_call = make_node("call_expression", children: [
        make_node("selector_expression", children: [
          make_node("identifier", text: "builder"),
          make_node("field_identifier", text: "SetName")
        ]),
        make_node("argument_list", children: [])
      ])

      outer_call = make_node("call_expression", children: [
        make_node("selector_expression", children: [
          inner_call,
          make_node("field_identifier", text: "Build")
        ]),
        make_node("argument_list", children: [])
      ])

      ast = wrap_program([
        make_node("function_declaration", start_row: 0, end_row: 2, children: [
          make_node("identifier", text: "create"),
          make_node("parameter_list", children: []),
          make_node("block", children: [
            make_node("expression_statement", children: [outer_call])
          ])
        ])
      ])

      entities = GoExtractor.extract_entities("factory.go", ast, "func create() {\n  builder.SetName(\"x\").Build()\n}")
      func = Enum.find(entities, &(&1.name == "create"))

      assert func != nil
      assert "Build" in func.calls
      assert "builder.SetName" in func.calls
    end
  end

  describe "edge cases" do
    test "function declaration without children is handled" do
      ast = wrap_program([
        %{"kind" => "function_declaration", "name" => "bare",
          "start_row" => 0, "end_row" => 0, "start_col" => 0, "end_col" => 0, "text" => ""}
      ])

      entities = GoExtractor.extract_entities("test.go", ast, "func bare() {}")
      func = Enum.find(entities, &(&1.name == "bare"))

      assert func != nil
      assert func.entity_type == :function
    end

    test "method declaration without children returns nil receiver" do
      ast = wrap_program([
        %{"kind" => "method_declaration",
          "start_row" => 0, "end_row" => 0, "start_col" => 0, "end_col" => 0, "text" => ""}
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
      ast = wrap_program([
        make_node("function_declaration", start_row: 0, end_row: 1, children: [
          make_node("identifier", text: "test"),
          make_node("parameter_list", children: []),
          make_node("block", children: [
            make_node("expression_statement", children: [
              %{"kind" => "call_expression", "start_row" => 0, "end_row" => 0,
                "start_col" => 0, "end_col" => 0, "text" => ""}
            ])
          ])
        ])
      ])

      entities = GoExtractor.extract_entities("test.go", ast, "func test() {\n}")
      func = Enum.find(entities, &(&1.name == "test"))
      assert func != nil
      assert func.calls == []
    end

    test "selector_expression with text fallback" do
      ast = wrap_program([
        make_node("function_declaration", start_row: 0, end_row: 1, children: [
          make_node("identifier", text: "test"),
          make_node("parameter_list", children: []),
          make_node("block", children: [
            make_node("expression_statement", children: [
              make_node("call_expression", children: [
                %{"kind" => "selector_expression", "text" => "os.Exit",
                  "start_row" => 0, "end_row" => 0, "start_col" => 0, "end_col" => 0},
                make_node("argument_list", children: [])
              ])
            ])
          ])
        ])
      ])

      entities = GoExtractor.extract_entities("test.go", ast, "func test() {\n  os.Exit(1)\n}")
      func = Enum.find(entities, &(&1.name == "test"))

      assert "os.Exit" in func.calls
    end
  end

  describe "content extraction" do
    test "entity content matches source lines" do
      ast = wrap_program([
        make_node("function_declaration", start_row: 0, end_row: 2, children: [
          make_node("identifier", text: "Hello"),
          make_node("parameter_list", children: []),
          make_node("block", children: [])
        ])
      ])

      source = "func Hello() {\n  return\n}"
      entities = GoExtractor.extract_entities("greet.go", ast, source)
      func = Enum.find(entities, &(&1.name == "Hello"))

      assert func.content == "func Hello() {\n  return\n}"
    end
  end

  describe "complete Go file" do
    test "extracts all entities from a realistic Go file" do
      ast = wrap_program([
        make_node("package_clause", children: [
          make_node("package_identifier", text: "server")
        ]),
        make_node("import_declaration", children: [
          make_node("import_spec_list", children: [
            make_node("import_spec", children: [
              make_node("interpreted_string_literal", text: "\"fmt\"")
            ]),
            make_node("import_spec", children: [
              make_node("interpreted_string_literal", text: "\"net/http\"")
            ])
          ])
        ]),
        make_node("type_declaration", children: [
          make_node("type_spec", start_row: 7, end_row: 10, children: [
            make_node("type_identifier", text: "App"),
            make_node("struct_type", children: [
              make_node("field_declaration", children: [
                make_node("field_identifier", text: "Name")
              ])
            ])
          ])
        ]),
        make_node("method_declaration", start_row: 12, end_row: 15, children: [
          make_node("parameter_list", children: [
            make_node("parameter_declaration", children: [
              make_node("identifier", text: "a"),
              make_node("pointer_type", children: [
                make_node("type_identifier", text: "App")
              ])
            ])
          ]),
          make_node("field_identifier", text: "Run"),
          make_node("parameter_list", children: [
            make_node("parameter_declaration", children: [
              make_node("identifier", text: "addr")
            ])
          ]),
          make_node("block", children: [
            make_node("expression_statement", children: [
              make_node("call_expression", children: [
                make_node("selector_expression", children: [
                  make_node("identifier", text: "fmt"),
                  make_node("field_identifier", text: "Println")
                ]),
                make_node("argument_list", children: [])
              ])
            ])
          ])
        ]),
        make_node("function_declaration", start_row: 17, end_row: 19, children: [
          make_node("identifier", text: "main"),
          make_node("parameter_list", children: []),
          make_node("block", children: [])
        ])
      ])

      source = Enum.join([
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
      ], "\n")

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
