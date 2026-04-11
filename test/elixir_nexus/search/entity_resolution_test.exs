defmodule ElixirNexus.Search.EntityResolutionTest do
  use ExUnit.Case, async: true

  alias ElixirNexus.Search.EntityResolution

  describe "matches_entity_name?/2" do
    test "exact match (same case)" do
      assert EntityResolution.matches_entity_name?("MyFunction", "MyFunction")
    end

    test "exact match (case-insensitive)" do
      assert EntityResolution.matches_entity_name?("myfunction", "MyFunction")
      assert EntityResolution.matches_entity_name?("MyFunction", "myfunction")
    end

    test "call is qualified, entity is bare — Module.function matches function" do
      assert EntityResolution.matches_entity_name?("Module.render", "render")
      assert EntityResolution.matches_entity_name?("React.useState", "useState")
    end

    test "call is bare, entity is qualified — function matches Module.function" do
      assert EntityResolution.matches_entity_name?("render", "Module.render")
      assert EntityResolution.matches_entity_name?("useState", "React.useState")
    end

    test "no match — different names" do
      refute EntityResolution.matches_entity_name?("foo", "bar")
    end

    test "no match — partial substring without dot boundary" do
      refute EntityResolution.matches_entity_name?("foobar", "bar")
    end

    test "no match — empty call" do
      refute EntityResolution.matches_entity_name?("", "render")
    end

    test "no match — empty entity name" do
      refute EntityResolution.matches_entity_name?("render", "")
    end

    test "deeply qualified call matches bare entity" do
      assert EntityResolution.matches_entity_name?("Pkg.Sub.helper", "helper")
    end
  end

  describe "import_matches_file?/2" do
    test "bare package name (no slash) never matches" do
      refute EntityResolution.import_matches_file?("react", "/app/src/react.ts")
      refute EntityResolution.import_matches_file?("lodash", "/app/src/lodash.js")
    end

    test "@/ alias matches file path suffix" do
      assert EntityResolution.import_matches_file?(
               "@/components/ui/button",
               "/app/src/components/ui/button.tsx"
             )
    end

    test "./ relative import matches file" do
      assert EntityResolution.import_matches_file?(
               "./utils/format",
               "/app/src/utils/format.ts"
             )
    end

    test "../ relative import matches file" do
      assert EntityResolution.import_matches_file?(
               "../services/api",
               "/app/src/services/api.ts"
             )
    end

    test "extension stripping — .tsx / .ts / .js / .jsx all stripped" do
      for ext <- ~w(.tsx .ts .js .jsx) do
        assert EntityResolution.import_matches_file?(
                 "@/lib/util",
                 "/app/src/lib/util#{ext}"
               )
      end
    end

    test "no match — different path suffix" do
      refute EntityResolution.import_matches_file?(
               "@/components/button",
               "/app/src/components/card.tsx"
             )
    end

    test "no match — import matches only part of a segment" do
      refute EntityResolution.import_matches_file?(
               "@/components/button",
               "/app/src/components/icon-button.tsx"
             )
    end
  end

  describe "find_entity_multi_strategy/2" do
    defp entity(name, file_path \\ "/app/src/foo.ts") do
      %{entity: %{"name" => name, "file_path" => file_path}}
    end

    test "exact match returns the right entity" do
      entities = [entity("Foo"), entity("Bar"), entity("Baz")]
      assert EntityResolution.find_entity_multi_strategy("Bar", entities).entity["name"] == "Bar"
    end

    test "file-path-based match when no exact name match" do
      entities = [entity("default", "/app/src/my-component.tsx")]
      # "my-component" normalises to "mycomponent", same as basename
      result = EntityResolution.find_entity_multi_strategy("my-component", entities)
      assert result.entity["name"] == "default"
    end

    test "substring fallback" do
      entities = [entity("VeryLongComponentName")]
      result = EntityResolution.find_entity_multi_strategy("Component", entities)
      assert result.entity["name"] == "VeryLongComponentName"
    end

    test "returns nil when nothing matches" do
      entities = [entity("Alpha"), entity("Beta")]
      assert EntityResolution.find_entity_multi_strategy("Gamma", entities) == nil
    end

    test "exact match preferred over substring" do
      entities = [entity("render"), entity("MyRenderer")]
      result = EntityResolution.find_entity_multi_strategy("render", entities)
      assert result.entity["name"] == "render"
    end
  end
end
