defmodule ElixirNexus.Parsers.JavaScriptCallsTest do
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

  describe "call extraction" do
    test "simple function call is extracted" do
      ast =
        make_node("program",
          children: [
            make_node("function_declaration",
              name: "main",
              children: [
                make_node("formal_parameters", children: []),
                make_node("statement_block",
                  children: [
                    make_node("expression_statement",
                      children: [
                        make_node("call_expression",
                          children: [
                            make_node("identifier", text: "doStuff"),
                            make_node("arguments", children: [])
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

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "function main() { doStuff() }")
      func = Enum.find(entities, &(&1.name == "main"))

      assert "doStuff" in func.calls
    end

    test "chained calls do not produce duplicates" do
      # Simulates: db.collection("x").doc("y")
      inner_call =
        make_node("call_expression",
          children: [
            make_node("member_expression",
              children: [
                make_node("identifier", text: "db"),
                make_node("property_identifier", text: "collection")
              ]
            ),
            make_node("arguments",
              children: [
                make_node("string", text: "\"x\"")
              ]
            )
          ]
        )

      outer_call =
        make_node("call_expression",
          children: [
            make_node("member_expression",
              children: [
                inner_call,
                make_node("property_identifier", text: "doc")
              ]
            ),
            make_node("arguments",
              children: [
                make_node("string", text: "\"y\"")
              ]
            )
          ]
        )

      ast =
        make_node("program",
          children: [
            make_node("function_declaration",
              name: "query",
              children: [
                make_node("formal_parameters", children: []),
                make_node("statement_block",
                  children: [
                    make_node("expression_statement", children: [outer_call])
                  ]
                )
              ]
            )
          ]
        )

      entities =
        JavaScriptExtractor.extract_entities("test.js", ast, "function query() { db.collection(\"x\").doc(\"y\") }")

      func = Enum.find(entities, &(&1.name == "query"))

      # Each call name should appear exactly once
      call_counts = Enum.frequencies(func.calls)

      for {name, count} <- call_counts do
        assert count == 1, "Call '#{name}' appeared #{count} times, expected 1"
      end
    end

    test "new expression is extracted" do
      ast =
        make_node("program",
          children: [
            make_node("function_declaration",
              name: "init",
              children: [
                make_node("formal_parameters", children: []),
                make_node("statement_block",
                  children: [
                    make_node("expression_statement",
                      children: [
                        make_node("new_expression",
                          children: [
                            make_node("identifier", text: "Foo"),
                            make_node("arguments", children: [])
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

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "function init() { new Foo() }")
      func = Enum.find(entities, &(&1.name == "init"))

      assert "Foo" in func.calls
    end
  end

  describe "callee name extraction" do
    test "member_expression with text field only" do
      ast =
        make_node("program",
          children: [
            make_node("function_declaration",
              name: "test",
              children: [
                make_node("formal_parameters", children: []),
                make_node("statement_block",
                  children: [
                    make_node("expression_statement",
                      children: [
                        make_node("call_expression",
                          children: [
                            %{
                              "kind" => "member_expression",
                              "text" => "console.log",
                              "start_row" => 0,
                              "end_row" => 0,
                              "start_col" => 0,
                              "end_col" => 0
                            },
                            make_node("arguments", children: [])
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

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "function test() { console.log() }")
      func = Enum.find(entities, &(&1.name == "test"))

      assert func != nil
      assert "console.log" in func.calls
    end
  end

  describe "call_expression with direct name field" do
    test "extracts call name from name field directly" do
      ast =
        make_node("program",
          children: [
            make_node("function_declaration",
              name: "test",
              children: [
                make_node("formal_parameters", children: []),
                make_node("statement_block",
                  children: [
                    make_node("expression_statement",
                      children: [
                        %{
                          "kind" => "call_expression",
                          "name" => "directCall",
                          "start_row" => 0,
                          "end_row" => 0,
                          "start_col" => 0,
                          "end_col" => 0,
                          "text" => "directCall()"
                        }
                      ]
                    )
                  ]
                )
              ]
            )
          ]
        )

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "function test() { directCall() }")
      func = Enum.find(entities, &(&1.name == "test"))
      assert func != nil
      assert "directCall" in func.calls
    end
  end

  describe "new_expression with member callee" do
    test "new expression with non-identifier callee" do
      ast =
        make_node("program",
          children: [
            make_node("function_declaration",
              name: "init",
              children: [
                make_node("formal_parameters", children: []),
                make_node("statement_block",
                  children: [
                    make_node("expression_statement",
                      children: [
                        make_node("new_expression",
                          children: [
                            make_node("member_expression",
                              children: [
                                make_node("identifier", text: "ns"),
                                make_node("property_identifier", text: "Widget")
                              ]
                            ),
                            make_node("arguments", children: [])
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
      inner_call =
        make_node("call_expression",
          children: [
            make_node("identifier", text: "foo"),
            make_node("arguments", children: [])
          ]
        )

      member =
        make_node("member_expression",
          children: [
            inner_call,
            make_node("property_identifier", text: "bar")
          ]
        )

      outer_call =
        make_node("call_expression",
          children: [
            member,
            make_node("arguments", children: [])
          ]
        )

      ast =
        make_node("program",
          children: [
            make_node("function_declaration",
              name: "chained",
              children: [
                make_node("formal_parameters", children: []),
                make_node("statement_block",
                  children: [
                    make_node("expression_statement", children: [outer_call])
                  ]
                )
              ]
            )
          ]
        )

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "function chained() { foo().bar() }")
      func = Enum.find(entities, &(&1.name == "chained"))

      assert func != nil
      assert "bar" in func.calls
      assert "foo" in func.calls
    end
  end

  describe "member_expression callee with text fallback" do
    test "extracts callee name from text when children are empty" do
      ast =
        make_node("program",
          children: [
            make_node("function_declaration",
              name: "test",
              children: [
                make_node("formal_parameters", children: []),
                make_node("statement_block",
                  children: [
                    make_node("expression_statement",
                      children: [
                        make_node("call_expression",
                          children: [
                            %{
                              "kind" => "member_expression",
                              "text" => "app.listen",
                              "start_row" => 0,
                              "end_row" => 0,
                              "start_col" => 0,
                              "end_col" => 0
                            },
                            make_node("arguments", children: [])
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

      entities = JavaScriptExtractor.extract_entities("test.js", ast, "function test() { app.listen() }")
      func = Enum.find(entities, &(&1.name == "test"))

      assert func != nil
      assert "app.listen" in func.calls
    end
  end

  describe "JSX component usage as callees" do
    test "jsx_self_closing_element PascalCase tag extracted as call" do
      # Simulates: function Page() { return <Button />; }
      ast =
        make_node("program",
          children: [
            make_node("function_declaration",
              name: "Page",
              children: [
                make_node("statement_block",
                  children: [
                    make_node("return_statement",
                      children: [
                        make_node("jsx_self_closing_element",
                          children: [
                            make_node("identifier", text: "Button")
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

      entities = JavaScriptExtractor.extract_entities("page.tsx", ast, "function Page() { return <Button />; }")
      page = Enum.find(entities, &(&1.name == "Page"))

      assert page != nil
      assert "Button" in page.calls, "Expected <Button /> to be extracted as a call"
    end

    test "jsx_opening_element PascalCase tag extracted as call" do
      # Simulates: function Page() { return <Card>...</Card>; }
      ast =
        make_node("program",
          children: [
            make_node("function_declaration",
              name: "Page",
              children: [
                make_node("statement_block",
                  children: [
                    make_node("return_statement",
                      children: [
                        make_node("jsx_element",
                          children: [
                            make_node("jsx_opening_element",
                              children: [
                                make_node("identifier", text: "Card")
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

      entities = JavaScriptExtractor.extract_entities("page.tsx", ast, "function Page() { return <Card></Card>; }")
      page = Enum.find(entities, &(&1.name == "Page"))

      assert page != nil
      assert "Card" in page.calls, "Expected <Card> to be extracted as a call"
    end

    test "lowercase HTML intrinsics are NOT extracted as calls" do
      # Simulates: function Page() { return <div><span /></div>; }
      ast =
        make_node("program",
          children: [
            make_node("function_declaration",
              name: "Page",
              children: [
                make_node("statement_block",
                  children: [
                    make_node("return_statement",
                      children: [
                        make_node("jsx_self_closing_element",
                          children: [make_node("identifier", text: "div")]
                        ),
                        make_node("jsx_self_closing_element",
                          children: [make_node("identifier", text: "span")]
                        )
                      ]
                    )
                  ]
                )
              ]
            )
          ]
        )

      entities =
        JavaScriptExtractor.extract_entities("page.tsx", ast, "function Page() { return <div><span /></div>; }")

      page = Enum.find(entities, &(&1.name == "Page"))

      assert page != nil
      refute "div" in page.calls, "HTML intrinsic <div> should not be a call"
      refute "span" in page.calls, "HTML intrinsic <span> should not be a call"
    end

    test "multiple JSX components all extracted" do
      # Simulates: function Dashboard() { return <><Header /><Sidebar /><Main /></>; }
      ast =
        make_node("program",
          children: [
            make_node("function_declaration",
              name: "Dashboard",
              children: [
                make_node("statement_block",
                  children: [
                    make_node("return_statement",
                      children: [
                        make_node("jsx_self_closing_element",
                          children: [make_node("identifier", text: "Header")]
                        ),
                        make_node("jsx_self_closing_element",
                          children: [make_node("identifier", text: "Sidebar")]
                        ),
                        make_node("jsx_self_closing_element",
                          children: [make_node("identifier", text: "Main")]
                        )
                      ]
                    )
                  ]
                )
              ]
            )
          ]
        )

      entities = JavaScriptExtractor.extract_entities("dashboard.tsx", ast, "")
      dashboard = Enum.find(entities, &(&1.name == "Dashboard"))

      assert dashboard != nil
      assert "Header" in dashboard.calls
      assert "Sidebar" in dashboard.calls
      assert "Main" in dashboard.calls
    end
  end
end
