defmodule ElixirNexus.Parsers.PythonImportsTest do
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
