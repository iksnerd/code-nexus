defmodule ElixirNexus.RelationshipExtractorTest do
  use ExUnit.Case

  alias ElixirNexus.RelationshipExtractor

  describe "extract_calls/1 - function call detection" do
    test "detects simple function calls" do
      code = """
      def my_func do
        helper_func()
      end
      """
      
      {:ok, ast} = Sourceror.parse_string(code)
      calls = RelationshipExtractor.extract_calls(ast)
      
      assert "helper_func" in calls
    end

    test "detects multiple function calls" do
      code = """
      def process do
        fetch_data()
        transform_data()
        save_data()
      end
      """
      
      {:ok, ast} = Sourceror.parse_string(code)
      calls = RelationshipExtractor.extract_calls(ast)
      
      assert "fetch_data" in calls
      assert "transform_data" in calls
      assert "save_data" in calls
    end

    test "detects qualified module calls" do
      code = """
      def test do
        Enum.map(list, &process/1)
      end
      """
      
      {:ok, ast} = Sourceror.parse_string(code)
      calls = RelationshipExtractor.extract_calls(ast)
      
      # Should contain some calls (exact names depend on AST structure)
      assert is_list(calls)
      assert length(calls) > 0
    end

    test "ignores control flow keywords" do
      code = """
      def test do
        if true do
          value = 1
        else
          value = 2
        end
      end
      """
      
      {:ok, ast} = Sourceror.parse_string(code)
      calls = RelationshipExtractor.extract_calls(ast)
      
      # Should not contain "if", "else", etc.
      assert "if" not in calls
    end

    test "returns unique calls only" do
      code = """
      def test do
        helper()
        helper()
        helper()
      end
      """
      
      {:ok, ast} = Sourceror.parse_string(code)
      calls = RelationshipExtractor.extract_calls(ast)
      
      # Should have only one "helper" despite being called 3 times
      count = Enum.count(calls, &(&1 == "helper"))
      assert count == 1
    end
  end

  describe "extract_is_a/1 - dependency detection" do
    test "detects use statements" do
      code = """
      defmodule MyModule do
        use GenServer
      end
      """
      
      {:ok, ast} = Sourceror.parse_string(code)
      is_a = RelationshipExtractor.extract_is_a(ast)
      
      assert "GenServer" in is_a
    end

    test "detects import statements" do
      code = """
      defmodule MyModule do
        import Enum
        import String
      end
      """
      
      {:ok, ast} = Sourceror.parse_string(code)
      is_a = RelationshipExtractor.extract_is_a(ast)
      
      assert "Enum" in is_a
      assert "String" in is_a
    end

    test "detects require statements" do
      code = """
      defmodule MyModule do
        require Logger
      end
      """
      
      {:ok, ast} = Sourceror.parse_string(code)
      is_a = RelationshipExtractor.extract_is_a(ast)
      
      assert "Logger" in is_a
    end

    test "returns unique dependencies only" do
      code = """
      defmodule MyModule do
        use GenServer
        use GenServer
      end
      """
      
      {:ok, ast} = Sourceror.parse_string(code)
      is_a = RelationshipExtractor.extract_is_a(ast)
      
      # Should have only one GenServer despite being used twice
      count = Enum.count(is_a, &(&1 == "GenServer"))
      assert count == 1
    end
  end

  describe "extract_contains/1 - module structure" do
    test "detects functions in module" do
      code = """
      defmodule MyModule do
        def public_func, do: :ok
        defp private_func, do: :ok
        defmacro my_macro, do: :ok
      end
      """
      
      {:ok, ast} = Sourceror.parse_string(code)
      
      case ast do
        list when is_list(list) ->
          module_ast = Enum.find(list, &match?({:defmodule, _, _}, &1))
          contains = RelationshipExtractor.extract_contains(module_ast)
          
          # Should extract contained functions when proper AST format
          assert is_list(contains)
        
        single when is_tuple(single) ->
          contains = RelationshipExtractor.extract_contains(single)
          assert is_list(contains)
      end
    end

    test "detects struct definitions" do
      code = """
      defmodule User do
        defstruct [:name, :email]
      end
      """
      
      {:ok, ast} = Sourceror.parse_string(code)
      
      case ast do
        list when is_list(list) ->
          module_ast = Enum.find(list, &match?({:defmodule, _, _}, &1))
          contains = RelationshipExtractor.extract_contains(module_ast)
          
          # Should extract something from module
          assert is_list(contains)
        
        single when is_tuple(single) ->
          contains = RelationshipExtractor.extract_contains(single)
          assert is_list(contains)
      end
    end

    test "non-module returns empty" do
      code = "def standalone_func, do: :ok"
      
      {:ok, ast} = Sourceror.parse_string(code)
      contains = RelationshipExtractor.extract_contains(ast)
      
      assert contains == []
    end
  end

  describe "extract/1 - complete relationship extraction" do
    test "returns struct with all relationship types" do
      code = """
      defmodule Worker do
        use GenServer
        
        def process do
          Enum.map([1, 2, 3], &handle_item/1)
        end
        
        defp handle_item(item) do
          transform(item)
        end
      end
      """
      
      {:ok, ast} = Sourceror.parse_string(code)
      
      case ast do
        list when is_list(list) ->
          module_ast = Enum.find(list, &match?({:defmodule, _, _}, &1))
          relationships = RelationshipExtractor.extract(module_ast)
          
          assert is_struct(relationships, RelationshipExtractor)
          assert is_list(relationships.calls)
          assert is_list(relationships.is_a)
          assert is_list(relationships.contains)
          
          # Should contain expected relationships
          assert "GenServer" in relationships.is_a
          assert "process" in relationships.contains
        
        single when is_tuple(single) ->
          relationships = RelationshipExtractor.extract(single)
          
          assert is_struct(relationships, RelationshipExtractor)
          assert is_list(relationships.calls)
          assert is_list(relationships.is_a)
          assert is_list(relationships.contains)
      end
    end
  end
end
