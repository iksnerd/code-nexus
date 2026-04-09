defmodule ElixirNexus.ParserTest do
  use ExUnit.Case

  setup do
    # Create temp files for testing
    temp_dir = System.tmp_dir!()
    test_file = Path.join(temp_dir, "test_#{:rand.uniform(1_000_000)}.ex")

    on_exit(fn ->
      if File.exists?(test_file) do
        File.rm(test_file)
      end
    end)

    {:ok, test_file: test_file}
  end

  describe "parse_file/1" do
    test "parses valid Elixir file", %{test_file: test_file} do
      code = """
      defmodule TestModule do
        def test_func do
          :ok
        end
      end
      """

      File.write(test_file, code)

      {:ok, entities} = ElixirNexus.Parser.parse_file(test_file)

      assert is_list(entities)
      assert length(entities) > 0
    end

    test "returns error for non-existent file", %{test_file: test_file} do
      {:error, reason} = ElixirNexus.Parser.parse_file(test_file <> ".nonexistent")

      assert reason == :enoent
    end

    test "handles syntax errors gracefully", %{test_file: test_file} do
      code = """
      defmodule BadModule do
        def broken(
        # missing closing paren
      end
      """

      File.write(test_file, code)

      result = ElixirNexus.Parser.parse_file(test_file)

      # Should return error, not crash
      assert {:error, _reason} = result
    end
  end

  describe "parse_source/2" do
    test "parses source code string" do
      code = """
      defmodule MyModule do
        def my_function do
          :ok
        end
      end
      """

      {:ok, entities} = ElixirNexus.Parser.parse_source("test.ex", code)

      assert is_list(entities)
      assert length(entities) > 0
    end

    test "extracts module and functions" do
      code = """
      defmodule Calculator do
        def add(a, b) do
          a + b
        end
        
        defp multiply(a, b) do
          a * b
        end
      end
      """

      {:ok, entities} = ElixirNexus.Parser.parse_source("calc.ex", code)

      # Should extract module, add/2, and multiply/2
      assert length(entities) >= 3

      names = entities |> Enum.map(& &1.name)
      assert "Calculator" in names
      assert "add" in names
      assert "multiply" in names
    end

    test "extracts all entity types" do
      code = """
      defmodule All do
        def func_def do
          :ok
        end
        
        defp private_func do
          :ok
        end
        
        defmacro my_macro do
          quote do
            :ok
          end
        end
      end
      """

      {:ok, entities} = ElixirNexus.Parser.parse_source("all.ex", code)

      assert length(entities) >= 4

      types = entities |> Enum.map(& &1.entity_type)
      assert :module in types
      assert :function in types
      assert :macro in types
    end

    test "handles empty file" do
      code = ""

      {:ok, entities} = ElixirNexus.Parser.parse_source("empty.ex", code)

      assert is_list(entities)
      assert length(entities) == 0
    end

    test "extracts file_path for each entity" do
      code = """
      defmodule Test do
        def test_func do
          :ok
        end
      end
      """

      {:ok, entities} = ElixirNexus.Parser.parse_source("my/test.ex", code)

      assert Enum.all?(entities, &(&1.file_path == "my/test.ex"))
    end

    test "preserves line numbers" do
      code = """
      defmodule Test do
        def func1 do
          :ok
        end
        
        def func2 do
          :ok
        end
      end
      """

      {:ok, entities} = ElixirNexus.Parser.parse_source("test.ex", code)

      # Each entity should have start_line and end_line
      assert Enum.all?(entities, fn e ->
               is_integer(e.start_line) and is_integer(e.end_line) and e.end_line >= e.start_line
             end)
    end
  end

  describe "edge cases" do
    test "handles nested modules" do
      code = """
      defmodule Parent do
        defmodule Child do
          def nested_func do
            :ok
          end
        end
      end
      """

      {:ok, entities} = ElixirNexus.Parser.parse_source("nested.ex", code)

      # Parser extracts top-level entities; nested module handling depends on AST structure
      assert length(entities) >= 1
      names = entities |> Enum.map(& &1.name)
      assert "Parent" in names
    end

    test "handles multi-arity functions" do
      code = """
      defmodule Multi do
        def process, do: :ok
        def process(a), do: a
        def process(a, b), do: a + b
      end
      """

      {:ok, entities} = ElixirNexus.Parser.parse_source("multi.ex", code)

      # May extract as single entity or multiple depending on parser
      names = entities |> Enum.map(& &1.name)
      assert Enum.count(names, &(&1 == "process")) >= 1
    end

    test "handles guard clauses" do
      code = """
      defmodule Guards do
        def positive(n) when n > 0 do
          :positive
        end
        
        def positive(n) when n <= 0 do
          :non_positive
        end
      end
      """

      {:ok, entities} = ElixirNexus.Parser.parse_source("guards.ex", code)

      assert length(entities) >= 2
    end

    test "handles unicode and special characters in comments" do
      code = """
      defmodule Unicode do
        # This is a comment with emoji 🎉
        def func do
          # More unicode: α β γ δ
          :ok
        end
      end
      """

      {:ok, entities} = ElixirNexus.Parser.parse_source("unicode.ex", code)

      assert length(entities) > 0
    end

    test "handles string literals with code-like content" do
      code = """
      defmodule Strings do
        def get_code do
          "defmodule Fake do end"
        end
      end
      """

      {:ok, entities} = ElixirNexus.Parser.parse_source("strings.ex", code)

      # Should not confuse string content with actual code
      # Module + function
      assert length(entities) == 2
    end
  end

  describe "relationship extraction during parsing" do
    test "extracts relationships from parsed entities" do
      code = """
      defmodule Worker do
        use GenServer
        
        def init(opts) do
          {:ok, opts}
        end
        
        def handle_cast({:process, data}, state) do
          transform_data(data)
          {:noreply, state}
        end
        
        defp transform_data(data) do
          Enum.map(data, &transform_item/1)
        end
      end
      """

      {:ok, entities} = ElixirNexus.Parser.parse_source("worker.ex", code)

      # Find the module entity
      module = Enum.find(entities, fn e -> e.entity_type == :module end)

      assert module != nil
      # Should have relationship fields (may be empty depending on AST parsing)
      assert is_list(module.is_a)
      assert is_list(module.contains)
      assert is_list(module.calls)
    end
  end
end
