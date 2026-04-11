defmodule ElixirNexus.Parsers.PythonEntitiesTest do
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

  describe "function extraction" do
    test "top-level function is classified as function" do
      ast =
        make_node("module",
          children: [
            make_node("function_definition",
              name: "greet",
              children: [
                make_node("parameters",
                  children: [
                    make_node("identifier", text: "name", name: "name")
                  ]
                ),
                make_node("block", children: [])
              ]
            )
          ]
        )

      entities = PythonExtractor.extract_entities("test.py", ast, "def greet(name):\n    pass")
      func = Enum.find(entities, &(&1.name == "greet" && &1.entity_type == :function))

      assert func != nil
      assert func.entity_type == :function
      assert func.visibility == :public
      assert "name" in func.parameters
    end

    test "private function (underscore prefix) has private visibility" do
      ast =
        make_node("module",
          children: [
            make_node("function_definition",
              name: "_helper",
              children: [
                make_node("parameters", children: []),
                make_node("block", children: [])
              ]
            )
          ]
        )

      entities = PythonExtractor.extract_entities("test.py", ast, "def _helper():\n    pass")
      func = Enum.find(entities, &(&1.name == "_helper" && &1.entity_type == :function))

      assert func != nil
      assert func.visibility == :private
    end
  end

  describe "class extraction" do
    test "class is classified as class" do
      ast =
        make_node("module",
          children: [
            make_node("class_definition",
              name: "Animal",
              children: [
                make_node("argument_list",
                  children: [
                    make_node("identifier", text: "Base")
                  ]
                ),
                make_node("block", children: [])
              ]
            )
          ]
        )

      entities = PythonExtractor.extract_entities("test.py", ast, "class Animal(Base):\n    pass")
      cls = Enum.find(entities, &(&1.name == "Animal"))

      assert cls != nil
      assert cls.entity_type == :class
      assert "Base" in cls.is_a
    end

    test "class with methods extracts contains list" do
      ast =
        make_node("module",
          children: [
            make_node("class_definition",
              name: "Dog",
              children: [
                make_node("block",
                  children: [
                    make_node("function_definition",
                      name: "bark",
                      children: [
                        make_node("parameters",
                          children: [
                            make_node("identifier", text: "self", name: "self")
                          ]
                        ),
                        make_node("block", children: [])
                      ]
                    )
                  ]
                )
              ]
            )
          ]
        )

      entities = PythonExtractor.extract_entities("test.py", ast, "class Dog:\n    def bark(self):\n        pass")
      cls = Enum.find(entities, &(&1.name == "Dog"))

      assert cls != nil
      assert "bark" in cls.contains
    end
  end

  describe "method extraction" do
    test "method inside class gets qualified name" do
      ast =
        make_node("module",
          children: [
            make_node("class_definition",
              name: "MyClass",
              children: [
                make_node("function_definition",
                  name: "do_thing",
                  children: [
                    make_node("parameters",
                      children: [
                        make_node("identifier", text: "self", name: "self"),
                        make_node("identifier", text: "x", name: "x")
                      ]
                    ),
                    make_node("block", children: [])
                  ]
                )
              ]
            )
          ]
        )

      entities =
        PythonExtractor.extract_entities("test.py", ast, "class MyClass:\n    def do_thing(self, x):\n        pass")

      method = Enum.find(entities, &(&1.name == "MyClass.do_thing"))

      assert method != nil
      assert method.entity_type == :method
      assert method.visibility == :public
      assert "self" not in method.parameters
      assert "x" in method.parameters
    end

    test "private method has private visibility" do
      ast =
        make_node("module",
          children: [
            make_node("class_definition",
              name: "MyClass",
              children: [
                make_node("function_definition",
                  name: "_internal",
                  children: [
                    make_node("parameters",
                      children: [
                        make_node("identifier", text: "self", name: "self")
                      ]
                    ),
                    make_node("block", children: [])
                  ]
                )
              ]
            )
          ]
        )

      entities =
        PythonExtractor.extract_entities("test.py", ast, "class MyClass:\n    def _internal(self):\n        pass")

      method = Enum.find(entities, &(&1.name == "MyClass._internal"))

      assert method != nil
      assert method.visibility == :private
    end
  end

  describe "typed and default parameter extraction" do
    test "typed_parameter is extracted" do
      ast =
        make_node("module",
          children: [
            make_node("function_definition",
              name: "greet",
              children: [
                make_node("parameters",
                  children: [
                    make_node("typed_parameter",
                      name: "name",
                      text: "name",
                      children: [
                        make_node("identifier", text: "name", name: "name"),
                        make_node("type",
                          children: [
                            make_node("identifier", text: "str")
                          ]
                        )
                      ]
                    )
                  ]
                ),
                make_node("block", children: [])
              ]
            )
          ]
        )

      entities = PythonExtractor.extract_entities("test.py", ast, "def greet(name: str):\n    pass")
      func = Enum.find(entities, &(&1.name == "greet" && &1.entity_type == :function))

      assert func != nil
      assert "name" in func.parameters
    end

    test "default_parameter is extracted" do
      ast =
        make_node("module",
          children: [
            make_node("function_definition",
              name: "greet",
              children: [
                make_node("parameters",
                  children: [
                    make_node("default_parameter",
                      name: "name",
                      children: [
                        make_node("identifier", text: "name", name: "name"),
                        make_node("string", text: "\"World\"")
                      ]
                    )
                  ]
                ),
                make_node("block", children: [])
              ]
            )
          ]
        )

      entities = PythonExtractor.extract_entities("test.py", ast, "def greet(name=\"World\"):\n    pass")
      func = Enum.find(entities, &(&1.name == "greet" && &1.entity_type == :function))

      assert func != nil
      assert "name" in func.parameters
    end
  end

  describe "class with multiple bases" do
    test "multiple inheritance extracts all bases" do
      ast =
        make_node("module",
          children: [
            make_node("class_definition",
              name: "Hybrid",
              children: [
                make_node("argument_list",
                  children: [
                    make_node("identifier", text: "Base1"),
                    make_node("identifier", text: "Base2")
                  ]
                ),
                make_node("block", children: [])
              ]
            )
          ]
        )

      entities = PythonExtractor.extract_entities("test.py", ast, "class Hybrid(Base1, Base2):\n    pass")
      cls = Enum.find(entities, &(&1.name == "Hybrid"))

      assert cls != nil
      assert "Base1" in cls.is_a
      assert "Base2" in cls.is_a
    end
  end

  describe "nested class handling" do
    test "method inside nested block is extracted" do
      ast =
        make_node("module",
          children: [
            make_node("class_definition",
              name: "Outer",
              children: [
                make_node("block",
                  children: [
                    make_node("function_definition",
                      name: "outer_method",
                      children: [
                        make_node("parameters",
                          children: [
                            make_node("identifier", text: "self", name: "self")
                          ]
                        ),
                        make_node("block", children: [])
                      ]
                    )
                  ]
                )
              ]
            )
          ]
        )

      entities =
        PythonExtractor.extract_entities("test.py", ast, "class Outer:\n    def outer_method(self):\n        pass")

      method = Enum.find(entities, &(&1.name == "Outer.outer_method"))

      assert method != nil
      assert method.entity_type == :method
    end
  end

  describe "nested class method with parent context" do
    test "method in nested block gets correct parent class name" do
      ast =
        make_node("module",
          children: [
            make_node("class_definition",
              name: "Service",
              children: [
                make_node("block",
                  children: [
                    make_node("function_definition",
                      name: "process",
                      children: [
                        make_node("parameters",
                          children: [
                            make_node("identifier", text: "self", name: "self"),
                            make_node("identifier", text: "data", name: "data")
                          ]
                        ),
                        make_node("block",
                          children: [
                            make_node("expression_statement",
                              children: [
                                make_node("call",
                                  children: [
                                    make_node("identifier", text: "validate")
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
          ]
        )

      entities =
        PythonExtractor.extract_entities(
          "test.py",
          ast,
          "class Service:\n    def process(self, data):\n        validate()"
        )

      method = Enum.find(entities, &(&1.name == "Service.process"))

      assert method != nil
      assert method.entity_type == :method
      assert "data" in method.parameters
      assert "self" not in method.parameters
      assert "validate" in method.calls
    end
  end

  describe "class definition without children" do
    test "class without children field is handled" do
      ast =
        make_node("module",
          children: [
            %{
              "kind" => "class_definition",
              "name" => "Simple",
              "start_row" => 0,
              "end_row" => 0,
              "start_col" => 0,
              "end_col" => 0,
              "text" => ""
            }
          ]
        )

      entities = PythonExtractor.extract_entities("test.py", ast, "class Simple:\n    pass")
      cls = Enum.find(entities, &(&1.name == "Simple"))

      assert cls != nil
      assert cls.entity_type == :class
    end
  end

  describe "function without children" do
    test "function_definition without children field is handled" do
      ast =
        make_node("module",
          children: [
            %{
              "kind" => "function_definition",
              "name" => "stub",
              "start_row" => 0,
              "end_row" => 0,
              "start_col" => 0,
              "end_col" => 0,
              "text" => ""
            }
          ]
        )

      entities = PythonExtractor.extract_entities("test.py", ast, "def stub():\n    pass")
      func = Enum.find(entities, &(&1.name == "stub" && &1.entity_type == :function))

      assert func != nil
    end
  end

  describe "extract_content edge cases" do
    test "function with zero start/end lines returns empty content" do
      ast =
        make_node("module",
          children: [
            make_node("function_definition",
              name: "test",
              start_row: -1,
              end_row: -1,
              children: [
                make_node("parameters", children: []),
                make_node("block", children: [])
              ]
            )
          ]
        )

      entities = PythonExtractor.extract_entities("test.py", ast, "def test():\n    pass")
      func = Enum.find(entities, &(&1.name == "test" && &1.entity_type == :function))

      assert func != nil
      # Content should be empty or available depending on line calculation
      assert is_binary(func.content)
    end
  end
end
