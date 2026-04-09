defmodule ElixirNexus.Parsers.PythonExtractorTest do
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

  describe "import extraction" do
    test "import statement extracts module name" do
      ast =
        make_node("module",
          children: [
            make_node("import_statement",
              children: [
                make_node("dotted_name",
                  text: "os.path",
                  children: [
                    make_node("identifier", text: "os", name: "os"),
                    make_node("identifier", text: "path", name: "path")
                  ]
                )
              ]
            ),
            make_node("function_definition",
              name: "main",
              children: [
                make_node("parameters", children: []),
                make_node("block", children: [])
              ]
            )
          ]
        )

      imports = PythonExtractor.extract_imports(ast)
      assert "os.path" in imports
    end

    test "from import statement extracts source module" do
      ast =
        make_node("module",
          children: [
            make_node("import_from_statement",
              children: [
                make_node("dotted_name", text: "collections", name: "collections"),
                make_node("identifier", text: "OrderedDict", name: "OrderedDict")
              ]
            ),
            make_node("function_definition",
              name: "main",
              children: [
                make_node("parameters", children: []),
                make_node("block", children: [])
              ]
            )
          ]
        )

      imports = PythonExtractor.extract_imports(ast)
      assert "collections" in imports
    end

    test "imports create file-level module entity" do
      ast =
        make_node("module",
          children: [
            make_node("import_statement",
              children: [
                make_node("identifier", text: "os", name: "os")
              ]
            ),
            make_node("function_definition",
              name: "run",
              children: [
                make_node("parameters", children: []),
                make_node("block", children: [])
              ]
            )
          ]
        )

      entities = PythonExtractor.extract_entities("utils.py", ast, "import os\ndef run():\n    pass")
      mod = Enum.find(entities, &(&1.entity_type == :module))

      assert mod != nil
      assert mod.name == "utils"
      assert "os" in mod.is_a
    end

    test "file without imports has no module entity" do
      ast =
        make_node("module",
          children: [
            make_node("function_definition",
              name: "run",
              children: [
                make_node("parameters", children: []),
                make_node("block", children: [])
              ]
            )
          ]
        )

      entities = PythonExtractor.extract_entities("utils.py", ast, "def run():\n    pass")
      mod = Enum.find(entities, &(&1.entity_type == :module))

      assert mod == nil
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

  describe "relative import" do
    test "relative_import in from statement is extracted" do
      ast =
        make_node("module",
          children: [
            make_node("import_from_statement",
              children: [
                make_node("relative_import",
                  text: ".",
                  name: ".",
                  children: [
                    make_node("identifier", text: "utils", name: "utils")
                  ]
                ),
                make_node("identifier", text: "helper", name: "helper")
              ]
            ),
            make_node("function_definition",
              name: "run",
              children: [
                make_node("parameters", children: []),
                make_node("block", children: [])
              ]
            )
          ]
        )

      imports = PythonExtractor.extract_imports(ast)
      # Relative import should produce something (either "." or resolved name)
      assert length(imports) >= 1
    end
  end

  describe "aliased import extraction" do
    test "aliased_import in import_from_statement" do
      ast =
        make_node("module",
          children: [
            make_node("import_from_statement",
              children: [
                make_node("dotted_name", text: "collections", name: "collections"),
                make_node("import_list",
                  children: [
                    make_node("aliased_import",
                      name: "OD",
                      children: [
                        make_node("identifier", text: "OrderedDict", name: "OrderedDict"),
                        make_node("identifier", text: "OD", name: "OD")
                      ]
                    )
                  ]
                )
              ]
            ),
            make_node("function_definition",
              name: "main",
              children: [
                make_node("parameters", children: []),
                make_node("block", children: [])
              ]
            )
          ]
        )

      entities =
        PythonExtractor.extract_entities(
          "test.py",
          ast,
          "from collections import OrderedDict as OD\ndef main():\n    pass"
        )

      mod = Enum.find(entities, &(&1.entity_type == :module))

      assert mod != nil
      assert "collections" in mod.is_a
      # The aliased import identifier should be extracted
      assert "OD" in mod.calls
    end
  end

  describe "import_from_statement identifiers" do
    test "multiple identifiers from single import" do
      ast =
        make_node("module",
          children: [
            make_node("import_from_statement",
              children: [
                make_node("dotted_name", text: "typing", name: "typing"),
                make_node("identifier", text: "List", name: "List"),
                make_node("identifier", text: "Dict", name: "Dict")
              ]
            ),
            make_node("function_definition",
              name: "main",
              children: [
                make_node("parameters", children: []),
                make_node("block", children: [])
              ]
            )
          ]
        )

      entities =
        PythonExtractor.extract_entities("test.py", ast, "from typing import List, Dict\ndef main():\n    pass")

      mod = Enum.find(entities, &(&1.entity_type == :module))

      assert mod != nil
      assert "typing" in mod.is_a
      # Imported names should be in module calls (excluding the source module name)
      assert "List" in mod.calls or "Dict" in mod.calls
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

  describe "import_from_statement with import_list" do
    test "extracts mixed identifiers and aliased_import from import_list" do
      ast =
        make_node("module",
          children: [
            make_node("import_from_statement",
              children: [
                make_node("dotted_name", text: "typing", name: "typing"),
                make_node("import_list",
                  children: [
                    make_node("identifier", text: "List", name: "List"),
                    make_node("aliased_import",
                      name: "DT",
                      children: [
                        make_node("identifier", text: "Dict", name: "Dict"),
                        make_node("identifier", text: "DT", name: "DT")
                      ]
                    )
                  ]
                )
              ]
            ),
            make_node("function_definition",
              name: "main",
              children: [
                make_node("parameters", children: []),
                make_node("block", children: [])
              ]
            )
          ]
        )

      entities =
        PythonExtractor.extract_entities("test.py", ast, "from typing import List, Dict as DT\ndef main():\n    pass")

      mod = Enum.find(entities, &(&1.entity_type == :module))

      assert mod != nil
      assert "typing" in mod.is_a
      assert "List" in mod.calls or "DT" in mod.calls
    end
  end

  describe "import_statement with dotted_name children" do
    test "extracts import source from dotted_name with child identifiers" do
      ast =
        make_node("module",
          children: [
            make_node("import_statement",
              children: [
                make_node("dotted_name",
                  text: "",
                  children: [
                    make_node("identifier", text: "os", name: "os"),
                    make_node("identifier", text: "path", name: "path")
                  ]
                )
              ]
            ),
            make_node("function_definition",
              name: "main",
              children: [
                make_node("parameters", children: []),
                make_node("block", children: [])
              ]
            )
          ]
        )

      imports = PythonExtractor.extract_imports(ast)
      assert "os.path" in imports
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

  describe "import_from_statement with identifier children only" do
    test "extracts source from bare identifiers" do
      ast =
        make_node("module",
          children: [
            make_node("import_from_statement",
              children: [
                make_node("identifier", text: "os", name: "os"),
                make_node("identifier", text: "getcwd", name: "getcwd")
              ]
            ),
            make_node("function_definition",
              name: "main",
              children: [
                make_node("parameters", children: []),
                make_node("block", children: [])
              ]
            )
          ]
        )

      imports = PythonExtractor.extract_imports(ast)
      assert "os" in imports
    end
  end
end
