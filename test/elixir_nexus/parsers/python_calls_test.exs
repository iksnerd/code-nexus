defmodule ElixirNexus.Parsers.PythonCallsTest do
  use ExUnit.Case, async: true

  alias ElixirNexus.Parsers.PythonExtractor

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

  describe "call extraction" do
    test "function calls are extracted" do
      ast =
        make_node("module",
          children: [
            make_node("function_definition",
              name: "main",
              children: [
                make_node("parameters", children: []),
                make_node("block",
                  children: [
                    make_node("expression_statement",
                      children: [
                        make_node("call",
                          children: [
                            make_node("identifier", text: "print")
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

      entities = PythonExtractor.extract_entities("test.py", ast, "def main():\n    print()")
      func = Enum.find(entities, &(&1.name == "main" && &1.entity_type == :function))

      assert func != nil
      assert "print" in func.calls
    end
  end

  describe "attribute call extraction" do
    test "method call via attribute is extracted" do
      ast =
        make_node("module",
          children: [
            make_node("function_definition",
              name: "main",
              children: [
                make_node("parameters", children: []),
                make_node("block",
                  children: [
                    make_node("expression_statement",
                      children: [
                        make_node("call",
                          children: [
                            make_node("attribute",
                              text: "os.path.join",
                              children: [
                                make_node("identifier", text: "os"),
                                make_node("identifier", text: "path"),
                                make_node("identifier", text: "join")
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

      entities = PythonExtractor.extract_entities("test.py", ast, "def main():\n    os.path.join()")
      func = Enum.find(entities, &(&1.name == "main" && &1.entity_type == :function))

      assert func != nil
      assert Enum.any?(func.calls, &String.contains?(&1, "os.path.join"))
    end
  end

  describe "decorator extraction" do
    test "decorators are included in is_a relationships" do
      ast =
        make_node("module",
          children: [
            make_node("decorated_definition",
              children: [
                make_node("decorator",
                  children: [
                    make_node("identifier", text: "staticmethod")
                  ]
                ),
                make_node("function_definition",
                  name: "create",
                  children: [
                    make_node("decorator",
                      children: [
                        make_node("identifier", text: "staticmethod")
                      ]
                    ),
                    make_node("parameters", children: []),
                    make_node("block", children: [])
                  ]
                )
              ]
            )
          ]
        )

      entities = PythonExtractor.extract_entities("test.py", ast, "@staticmethod\ndef create():\n    pass")
      func = Enum.find(entities, &(&1.name == "create" && &1.entity_type == :function))

      assert func != nil
      assert "@staticmethod" in func.is_a
    end

    test "decorator with arguments is extracted" do
      ast =
        make_node("module",
          children: [
            make_node("function_definition",
              name: "index",
              children: [
                make_node("decorator",
                  children: [
                    make_node("call",
                      children: [
                        make_node("attribute", text: "app.route"),
                        make_node("argument_list", children: [])
                      ]
                    )
                  ]
                ),
                make_node("parameters", children: []),
                make_node("block", children: [])
              ]
            )
          ]
        )

      entities = PythonExtractor.extract_entities("test.py", ast, "@app.route('/')\ndef index():\n    pass")
      func = Enum.find(entities, &(&1.name == "index" && &1.entity_type == :function))

      assert func != nil
      assert "@app.route" in func.is_a
    end

    test "decorator with name field" do
      ast =
        make_node("module",
          children: [
            make_node("function_definition",
              name: "test_func",
              children: [
                make_node("decorator",
                  children: [
                    make_node("identifier", text: "pytest_mark", name: "pytest_mark")
                  ]
                ),
                make_node("parameters", children: []),
                make_node("block", children: [])
              ]
            )
          ]
        )

      entities = PythonExtractor.extract_entities("test.py", ast, "@pytest_mark\ndef test_func():\n    pass")
      func = Enum.find(entities, &(&1.name == "test_func" && &1.entity_type == :function))

      assert func != nil
      assert "@pytest_mark" in func.is_a
    end
  end

  describe "extract_decorators edge cases" do
    test "node without children returns empty list" do
      result = PythonExtractor.extract_decorators(%{})
      assert result == []
    end

    test "node with no decorator children returns empty list" do
      result =
        PythonExtractor.extract_decorators(%{
          "children" => [
            make_node("identifier", text: "foo")
          ]
        })

      assert result == []
    end
  end

  describe "decorator with no resolvable name" do
    test "decorator call with no identifier or attribute child returns nil" do
      ast =
        make_node("module",
          children: [
            make_node("function_definition",
              name: "test_func",
              children: [
                make_node("decorator",
                  children: [
                    make_node("call",
                      children: [
                        make_node("number", text: "123")
                      ]
                    )
                  ]
                ),
                make_node("parameters", children: []),
                make_node("block", children: [])
              ]
            )
          ]
        )

      entities = PythonExtractor.extract_entities("test.py", ast, "@123\ndef test_func():\n    pass")
      func = Enum.find(entities, &(&1.name == "test_func" && &1.entity_type == :function))

      assert func != nil
      # The decorator should be filtered out (nil) so is_a should not contain it
      refute Enum.any?(func.is_a, &is_nil/1)
    end
  end

  describe "decorator with no children at all" do
    test "decorator node without children returns nil" do
      result =
        PythonExtractor.extract_decorators(%{
          "children" => [
            %{"kind" => "decorator", "start_row" => 0, "end_row" => 0, "start_col" => 0, "end_col" => 0, "text" => ""}
          ]
        })

      # The decorator has no children, so extract_decorator_name should return nil
      assert result == []
    end
  end

  describe "import-qualified call extraction" do
    test "call to from-imported symbol is qualified with module path" do
      ast =
        make_node("module",
          children: [
            make_node("import_from_statement",
              start_row: 0,
              children: [
                make_node("identifier", text: "render_variant")
              ]
            ),
            make_node("function_definition",
              name: "create_ad",
              children: [
                make_node("parameters", children: []),
                make_node("block",
                  children: [
                    make_node("expression_statement",
                      children: [
                        make_node("call",
                          children: [
                            make_node("identifier", text: "render_variant")
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

      source = "from meta_ads.postprocess import render_variant\ndef create_ad():\n    render_variant()"

      entities = PythonExtractor.extract_entities("ad_render.py", ast, source)
      func = Enum.find(entities, &(&1.name == "create_ad" && &1.entity_type == :function))

      assert func != nil
      assert "meta_ads.postprocess.render_variant" in func.calls
      refute "render_variant" in func.calls
    end

    test "calls to non-imported symbols are kept bare" do
      ast =
        make_node("module",
          children: [
            make_node("function_definition",
              name: "main",
              children: [
                make_node("parameters", children: []),
                make_node("block",
                  children: [
                    make_node("expression_statement",
                      children: [
                        make_node("call",
                          children: [
                            make_node("identifier", text: "print")
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

      source = "def main():\n    print()"
      entities = PythonExtractor.extract_entities("test.py", ast, source)
      func = Enum.find(entities, &(&1.name == "main" && &1.entity_type == :function))

      assert func != nil
      assert "print" in func.calls
    end

    test "module entity calls list uses qualified names" do
      ast =
        make_node("module",
          children: [
            make_node("import_from_statement",
              start_row: 0,
              children: [
                make_node("import_list",
                  children: [
                    make_node("identifier", text: "render_variant"),
                    make_node("identifier", text: "assemble_video")
                  ]
                )
              ]
            )
          ]
        )

      source = "from meta_ads.video import render_variant, assemble_video"
      entities = PythonExtractor.extract_entities("app.py", ast, source)
      mod = Enum.find(entities, &(&1.entity_type == :module))

      assert mod != nil
      assert "meta_ads.video.render_variant" in mod.calls
      assert "meta_ads.video.assemble_video" in mod.calls
      assert mod.is_a == ["meta_ads.video"]
    end
  end

  describe "call with name field" do
    test "call expression with direct name field" do
      ast =
        make_node("module",
          children: [
            make_node("function_definition",
              name: "main",
              children: [
                make_node("parameters", children: []),
                make_node("block",
                  children: [
                    make_node("expression_statement",
                      children: [
                        %{
                          "kind" => "call",
                          "name" => "direct_call",
                          "start_row" => 0,
                          "end_row" => 0,
                          "start_col" => 0,
                          "end_col" => 0,
                          "text" => "direct_call()"
                        }
                      ]
                    )
                  ]
                )
              ]
            )
          ]
        )

      entities = PythonExtractor.extract_entities("test.py", ast, "def main():\n    direct_call()")
      func = Enum.find(entities, &(&1.name == "main" && &1.entity_type == :function))

      assert func != nil
      assert "direct_call" in func.calls
    end

    test "deeply nested call missed by NIF is recovered from content (content-enrichment)" do
      # Simulates _run_pipeline calling render_variant inside a try/for block —
      # the NIF depth limit filters it from the AST. Only the import_from_statement
      # node is present. The content-enrichment pass must add the qualified call.
      ast =
        make_node("module",
          children: [
            make_node("import_from_statement",
              start_row: 0,
              children: [make_node("identifier", text: "render_variant")]
            ),
            make_node("function_definition",
              name: "_run_pipeline",
              start_row: 2,
              end_row: 5,
              children: [
                make_node("parameters", children: []),
                # block has NO call node (simulates NIF depth filtering)
                make_node("block", children: [])
              ]
            )
          ]
        )

      # Source contains the bare symbol in the function body
      source =
        "from meta_ads.postprocess import render_variant\n\ndef _run_pipeline():\n    result = render_variant(ad_id=1)\n    return result"

      entities = PythonExtractor.extract_entities("ad_render.py", ast, source)
      func = Enum.find(entities, &(&1.name == "_run_pipeline"))

      assert func != nil

      assert "meta_ads.postprocess.render_variant" in func.calls,
             "content enrichment should add qualified call, got: #{inspect(func.calls)}"
    end

    test "parenthesized multi-line import qualifies calls correctly" do
      # Simulates: from meta_ads.postprocess import (
      #   render_variant,
      #   assemble_video,
      # )
      # import_list node is filtered by NIF — only the import_from_statement node
      # is present, with no identifier children. The source-text fallback must
      # extract render_variant and assemble_video.
      ast =
        make_node("module",
          children: [
            # NIF provides only the statement node, children stripped (no import_list)
            make_node("import_from_statement",
              start_row: 0,
              children: []
            ),
            make_node("function_definition",
              name: "render",
              children: [
                make_node("parameters", children: []),
                make_node("block",
                  children: [
                    make_node("expression_statement",
                      children: [
                        make_node("call",
                          children: [make_node("identifier", text: "render_variant")]
                        )
                      ]
                    )
                  ]
                )
              ]
            )
          ]
        )

      source =
        "from meta_ads.postprocess import (\n    render_variant,\n    assemble_video,\n)\ndef render():\n    render_variant()"

      entities = PythonExtractor.extract_entities("ad_render.py", ast, source)
      func = Enum.find(entities, &(&1.name == "render" && &1.entity_type == :function))

      assert func != nil

      assert "meta_ads.postprocess.render_variant" in func.calls,
             "expected qualified call, got: #{inspect(func.calls)}"

      refute "render_variant" in func.calls
    end
  end
end
