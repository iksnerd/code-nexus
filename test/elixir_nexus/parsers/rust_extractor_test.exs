defmodule ElixirNexus.Parsers.RustExtractorTest do
  use ExUnit.Case, async: true

  alias ElixirNexus.Parsers.RustExtractor

  defp make_node(kind, opts \\ []) do
    %{
      "kind" => kind,
      "start_row" => Keyword.get(opts, :start_row, 0),
      "end_row" => Keyword.get(opts, :end_row, 0),
      "children" => Keyword.get(opts, :children, [])
    }
    |> then(fn m -> if n = Keyword.get(opts, :name), do: Map.put(m, "name", n), else: m end)
    |> then(fn m -> if t = Keyword.get(opts, :text), do: Map.put(m, "text", t), else: m end)
  end

  describe "extract_params — self_parameter" do
    test "self_parameter produces 'self' in parameters list" do
      func_node =
        make_node("function_item",
          name: "greet",
          children: [
            make_node("parameters",
              children: [
                make_node("self_parameter",
                  children: [make_node("self", text: "self")]
                )
              ]
            ),
            make_node("block", children: [])
          ]
        )

      ast = make_node("source_file", children: [func_node])
      source = "fn greet(&self) {}"

      entities = RustExtractor.extract_entities("lib.rs", ast, source)
      func = Enum.find(entities, &(&1.name == "greet"))

      assert func != nil

      assert "self" in func.parameters,
             "Expected 'self' in params for self_parameter, got: #{inspect(func.parameters)}"
    end

    test "regular parameter still extracted alongside self" do
      func_node =
        make_node("function_item",
          name: "add",
          children: [
            make_node("parameters",
              children: [
                make_node("self_parameter",
                  children: [make_node("self", text: "self")]
                ),
                make_node("parameter",
                  children: [
                    make_node("identifier", name: "x", text: "x"),
                    make_node("type_identifier", text: "i32")
                  ]
                )
              ]
            ),
            make_node("block", children: [])
          ]
        )

      ast = make_node("source_file", children: [func_node])
      source = "fn add(&self, x: i32) {}"

      entities = RustExtractor.extract_entities("lib.rs", ast, source)
      func = Enum.find(entities, &(&1.name == "add"))

      assert func != nil
      assert "self" in func.parameters
      assert "x" in func.parameters
    end
  end
end
