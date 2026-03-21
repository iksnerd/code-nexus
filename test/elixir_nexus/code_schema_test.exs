defmodule ElixirNexus.CodeSchemaTest do
  use ExUnit.Case, async: true

  alias ElixirNexus.CodeSchema

  @source "defmodule MyApp do\n  def hello(name) do\n    IO.puts(name)\n  end\nend"

  describe "from_ast/3 - defmodule" do
    test "extracts module entity from defmodule AST" do
      ast =
        {:defmodule, [line: 1, end_line: 5],
         [
           {:__aliases__, [line: 1], [:MyApp]},
           [{{:__block__, [line: 1], [:do]}, {:def, [line: 2, end_line: 4], [{:hello, [line: 2], [{:name, [], nil}]}, [[do: {:IO, [], [:puts]}]]]}}]
         ]}

      result = CodeSchema.from_ast("lib/my_app.ex", ast, @source)

      assert result.entity_type == :module
      assert result.name == "MyApp"
      assert result.file_path == "lib/my_app.ex"
      assert result.start_line == 1
      assert result.visibility == :public
    end

    test "extracts nested module name" do
      ast =
        {:defmodule, [line: 1, end_line: 3],
         [
           {:__aliases__, [line: 1], [:MyApp, :Web, :Router]},
           [{{:__block__, [line: 1], [:do]}, nil}]
         ]}

      result = CodeSchema.from_ast("lib/router.ex", ast, "defmodule MyApp.Web.Router do\nend\n")

      assert result.name == "MyApp.Web.Router"
      assert result.module_path == "MyApp.Web.Router"
    end
  end

  describe "from_ast/3 - def" do
    test "extracts public function" do
      source = "def greet(name) do\n  \"Hello \#{name}\"\nend"
      ast = {:def, [line: 1, end_line: 3], [{:greet, [line: 1], [{:name, [], nil}]}, [[do: {:<<>>, [], ["Hello ", {:name, [], nil}]}]]]}

      result = CodeSchema.from_ast("lib/greeter.ex", ast, source)

      assert result.entity_type == :function
      assert result.name == "greet"
      assert result.visibility == :public
      assert result.parameters == ["name"]
    end

    test "extracts function with multiple parameters" do
      source = "def add(a, b) do\n  a + b\nend"
      ast = {:def, [line: 1, end_line: 3], [{:add, [line: 1], [{:a, [], nil}, {:b, [], nil}]}, [[do: {:+, [], [{:a, [], nil}, {:b, [], nil}]}]]]}

      result = CodeSchema.from_ast("lib/math.ex", ast, source)

      assert result.parameters == ["a", "b"]
    end
  end

  describe "from_ast/3 - defp" do
    test "extracts private function" do
      source = "defp internal(x) do\n  x * 2\nend"
      ast = {:defp, [line: 1, end_line: 3], [{:internal, [line: 1], [{:x, [], nil}]}, [[do: {:*, [], [{:x, [], nil}, 2]}]]]}

      result = CodeSchema.from_ast("lib/helper.ex", ast, source)

      assert result.entity_type == :function
      assert result.name == "internal"
      assert result.visibility == :private
    end
  end

  describe "from_ast/3 - defmacro" do
    test "extracts macro without guard" do
      source = "defmacro my_macro(expr) do\n  quote do: unquote(expr)\nend"
      ast = {:defmacro, [line: 1, end_line: 3], [{:my_macro, [line: 1], [{:expr, [], nil}]}, [[do: {:quote, [], [[do: {:unquote, [], [{:expr, [], nil}]}]]}]]]}

      result = CodeSchema.from_ast("lib/macros.ex", ast, source)

      assert result.entity_type == :macro
      assert result.name == "my_macro"
      assert result.visibility == :public
      assert result.parameters == ["expr"]
    end

    test "extracts macro with when guard" do
      source = "defmacro checked(val) when is_atom(val) do\n  val\nend"
      ast =
        {:defmacro, [line: 1, end_line: 3],
         [
           {:when, [line: 1],
            [{:checked, [line: 1], [{:val, [], nil}]}, {:is_atom, [line: 1], [{:val, [], nil}]}]},
           [[do: {:val, [], nil}]]
         ]}

      result = CodeSchema.from_ast("lib/macros.ex", ast, source)

      assert result.entity_type == :macro
      assert result.name == "checked"
      assert result.parameters == ["val"]
    end
  end

  describe "from_ast/3 - def with when guard" do
    test "extracts guarded function" do
      source = "def validate(x) when is_integer(x) do\n  :ok\nend"
      ast =
        {:def, [line: 1, end_line: 3],
         [
           {:when, [line: 1],
            [{:validate, [line: 1], [{:x, [], nil}]}, {:is_integer, [line: 1], [{:x, [], nil}]}]},
           [[do: :ok]]
         ]}

      result = CodeSchema.from_ast("lib/validator.ex", ast, source)

      assert result.entity_type == :function
      assert result.name == "validate"
      assert result.visibility == :public
      assert result.parameters == ["x"]
    end

    test "extracts guarded defp function as private" do
      source = "defp check(x) when is_binary(x) do\n  :ok\nend"
      ast =
        {:defp, [line: 1, end_line: 3],
         [
           {:when, [line: 1],
            [{:check, [line: 1], [{:x, [], nil}]}, {:is_binary, [line: 1], [{:x, [], nil}]}]},
           [[do: :ok]]
         ]}

      result = CodeSchema.from_ast("lib/check.ex", ast, source)

      assert result.visibility == :private
    end
  end

  describe "from_ast/3 - defstruct" do
    test "extracts struct with atom fields" do
      source = "defstruct [:name, :age]"
      # Plain atoms directly as args (simplified AST)
      ast = {:defstruct, [line: 1], [:name, :age]}

      result = CodeSchema.from_ast("lib/user.ex", ast, source)

      assert result.entity_type == :struct
      assert result.name == "defstruct"
      assert result.parameters == ["name", "age"]
    end

    test "extracts struct with keyword fields as tuples" do
      source = "defstruct name: nil, age: 0"
      # Keyword fields as {key, value} tuples
      ast = {:defstruct, [line: 1], [{:name, nil}, {:age, 0}]}

      result = CodeSchema.from_ast("lib/user.ex", ast, source)

      assert result.entity_type == :struct
      assert result.parameters == ["name", "age"]
    end

    test "extracts struct entity type and name" do
      source = "defstruct []"
      ast = {:defstruct, [line: 1], []}

      result = CodeSchema.from_ast("lib/empty.ex", ast, source)

      assert result.entity_type == :struct
      assert result.name == "defstruct"
      assert result.parameters == []
      assert result.calls == []
    end
  end

  describe "from_ast/3 - unrecognized nodes" do
    test "returns nil for unrecognized AST node" do
      assert CodeSchema.from_ast("lib/test.ex", {:unknown_form, [line: 1], []}, "") == nil
    end

    test "returns nil for a plain atom" do
      assert CodeSchema.from_ast("lib/test.ex", :something, "") == nil
    end

    test "returns nil for a string" do
      assert CodeSchema.from_ast("lib/test.ex", "not an ast", "") == nil
    end
  end
end
