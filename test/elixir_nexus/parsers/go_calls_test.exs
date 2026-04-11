defmodule ElixirNexus.Parsers.GoCallsTest do
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

  describe "call expressions" do
    test "extracts direct function call" do
      ast =
        wrap_program([
          make_node("function_declaration",
            start_row: 0,
            end_row: 2,
            children: [
              make_node("identifier", text: "main"),
              make_node("parameter_list", children: []),
              make_node("block",
                children: [
                  make_node("expression_statement",
                    children: [
                      make_node("call_expression",
                        children: [
                          make_node("identifier", text: "foo"),
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

      entities = GoExtractor.extract_entities("main.go", ast, "func main() {\n  foo()\n}")
      func = Enum.find(entities, &(&1.name == "main"))

      assert "foo" in func.calls
    end

    test "extracts package-qualified call" do
      ast =
        wrap_program([
          make_node("function_declaration",
            start_row: 0,
            end_row: 2,
            children: [
              make_node("identifier", text: "main"),
              make_node("parameter_list", children: []),
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
          )
        ])

      entities = GoExtractor.extract_entities("main.go", ast, "func main() {\n  fmt.Println()\n}")
      func = Enum.find(entities, &(&1.name == "main"))

      assert "fmt.Println" in func.calls
    end

    test "extracts multiple calls" do
      ast =
        wrap_program([
          make_node("function_declaration",
            start_row: 0,
            end_row: 4,
            children: [
              make_node("identifier", text: "run"),
              make_node("parameter_list", children: []),
              make_node("block",
                children: [
                  make_node("expression_statement",
                    children: [
                      make_node("call_expression",
                        children: [
                          make_node("identifier", text: "setup"),
                          make_node("argument_list", children: [])
                        ]
                      )
                    ]
                  ),
                  make_node("expression_statement",
                    children: [
                      make_node("call_expression",
                        children: [
                          make_node("selector_expression",
                            children: [
                              make_node("identifier", text: "log"),
                              make_node("field_identifier", text: "Info")
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
          )
        ])

      entities = GoExtractor.extract_entities("app.go", ast, "func run() {\n  setup()\n  log.Info()\n}")
      func = Enum.find(entities, &(&1.name == "run"))

      assert "setup" in func.calls
      assert "log.Info" in func.calls
    end

    test "extracts nested calls in arguments" do
      ast =
        wrap_program([
          make_node("function_declaration",
            start_row: 0,
            end_row: 2,
            children: [
              make_node("identifier", text: "main"),
              make_node("parameter_list", children: []),
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
                          make_node("argument_list",
                            children: [
                              make_node("call_expression",
                                children: [
                                  make_node("identifier", text: "getMessage"),
                                  make_node("argument_list", children: [])
                                ]
                              )
                            ]
                          )
                        ]
                      )
                    ]
                  )
                ]
              )
            ]
          )
        ])

      entities = GoExtractor.extract_entities("main.go", ast, "func main() {\n  fmt.Println(getMessage())\n}")
      func = Enum.find(entities, &(&1.name == "main"))

      assert "fmt.Println" in func.calls
      assert "getMessage" in func.calls
    end

    test "calls are deduplicated" do
      ast =
        wrap_program([
          make_node("function_declaration",
            start_row: 0,
            end_row: 3,
            children: [
              make_node("identifier", text: "process"),
              make_node("parameter_list", children: []),
              make_node("block",
                children: [
                  make_node("expression_statement",
                    children: [
                      make_node("call_expression",
                        children: [
                          make_node("identifier", text: "validate"),
                          make_node("argument_list", children: [])
                        ]
                      )
                    ]
                  ),
                  make_node("expression_statement",
                    children: [
                      make_node("call_expression",
                        children: [
                          make_node("identifier", text: "validate"),
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

      entities = GoExtractor.extract_entities("proc.go", ast, "func process() {\n  validate()\n  validate()\n}")
      func = Enum.find(entities, &(&1.name == "process"))

      call_counts = Enum.frequencies(func.calls)
      assert Map.get(call_counts, "validate") == 1
    end
  end

  describe "chained calls" do
    test "extracts chained method calls" do
      # Simulates: builder.SetName("x").Build()
      inner_call =
        make_node("call_expression",
          children: [
            make_node("selector_expression",
              children: [
                make_node("identifier", text: "builder"),
                make_node("field_identifier", text: "SetName")
              ]
            ),
            make_node("argument_list", children: [])
          ]
        )

      outer_call =
        make_node("call_expression",
          children: [
            make_node("selector_expression",
              children: [
                inner_call,
                make_node("field_identifier", text: "Build")
              ]
            ),
            make_node("argument_list", children: [])
          ]
        )

      ast =
        wrap_program([
          make_node("function_declaration",
            start_row: 0,
            end_row: 2,
            children: [
              make_node("identifier", text: "create"),
              make_node("parameter_list", children: []),
              make_node("block",
                children: [
                  make_node("expression_statement", children: [outer_call])
                ]
              )
            ]
          )
        ])

      entities = GoExtractor.extract_entities("factory.go", ast, "func create() {\n  builder.SetName(\"x\").Build()\n}")
      func = Enum.find(entities, &(&1.name == "create"))

      assert func != nil
      assert "Build" in func.calls
      assert "builder.SetName" in func.calls
    end
  end
end
