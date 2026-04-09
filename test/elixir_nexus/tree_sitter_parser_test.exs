defmodule ElixirNexus.TreeSitterParserTest do
  use ExUnit.Case, async: true

  alias ElixirNexus.TreeSitterParser

  describe "detect_language/1" do
    test "detects JavaScript for .js" do
      assert TreeSitterParser.detect_language("app.js") == :javascript
    end

    test "detects JavaScript for .jsx" do
      assert TreeSitterParser.detect_language("component.jsx") == :javascript
    end

    test "detects JavaScript for .mjs" do
      assert TreeSitterParser.detect_language("module.mjs") == :javascript
    end

    test "detects TypeScript for .ts" do
      assert TreeSitterParser.detect_language("service.ts") == :typescript
    end

    test "detects TSX for .tsx" do
      assert TreeSitterParser.detect_language("component.tsx") == :tsx
    end

    test "detects Python for .py" do
      assert TreeSitterParser.detect_language("script.py") == :python
    end

    test "detects Go for .go" do
      assert TreeSitterParser.detect_language("main.go") == :go
    end

    test "detects Rust for .rs" do
      assert TreeSitterParser.detect_language("lib.rs") == :rust
    end

    test "detects Java for .java" do
      assert TreeSitterParser.detect_language("App.java") == :java
    end

    test "detects Ruby for .rb" do
      assert TreeSitterParser.detect_language("server.rb") == :ruby
    end

    test "detects Elixir for .ex" do
      assert TreeSitterParser.detect_language("module.ex") == :elixir
    end

    test "detects Elixir for .exs" do
      assert TreeSitterParser.detect_language("test.exs") == :elixir
    end

    test "returns nil for unknown extension" do
      assert TreeSitterParser.detect_language("readme.txt") == nil
    end

    test "returns nil for no extension" do
      assert TreeSitterParser.detect_language("Makefile") == nil
    end

    test "handles nested paths" do
      assert TreeSitterParser.detect_language("/home/user/project/src/main.go") == :go
    end
  end

  describe "detect_language/1 - additional coverage" do
    test "returns nil for .cpp extension" do
      assert TreeSitterParser.detect_language("main.cpp") == nil
    end

    test "returns nil for .h extension" do
      assert TreeSitterParser.detect_language("header.h") == nil
    end
  end

  describe "parse_and_extract/2 - error path" do
    test "returns error for non-existent file" do
      assert {:error, :enoent} =
               TreeSitterParser.parse_and_extract("/tmp/does_not_exist_#{System.unique_integer()}.go")
    end
  end

  describe "parse_and_extract/2 - JSX component calls (NIF integration)" do
    # These tests go through the real NIF parser to ensure the full pipeline works:
    # source → tree-sitter NIF → AST → JavaScriptExtractor → entities with calls
    test "self-closing JSX components appear as calls" do
      source = """
      import { Button } from "@/components/ui/button";
      import { Card } from "@/components/ui/card";

      export default function Page() {
        return (
          <div>
            <Button />
            <Card />
          </div>
        );
      }
      """

      path = "/tmp/test_jsx_self_closing_#{System.unique_integer()}.tsx"
      File.write!(path, source)
      on_exit(fn -> File.rm(path) end)

      {:ok, entities} = TreeSitterParser.parse_and_extract(path)
      page = Enum.find(entities, &(&1.name == "Page"))

      assert page != nil, "Expected to find Page component"
      assert "Button" in page.calls, "Expected <Button /> to be an outgoing call"
      assert "Card" in page.calls, "Expected <Card /> to be an outgoing call"
    end

    test "opening/closing JSX elements appear as calls" do
      source = """
      export default function Layout({ children }) {
        return (
          <Sheet>
            <SheetContent>{children}</SheetContent>
          </Sheet>
        );
      }
      """

      path = "/tmp/test_jsx_opening_#{System.unique_integer()}.tsx"
      File.write!(path, source)
      on_exit(fn -> File.rm(path) end)

      {:ok, entities} = TreeSitterParser.parse_and_extract(path)
      layout = Enum.find(entities, &(&1.name == "Layout"))

      assert layout != nil, "Expected to find Layout component"
      assert "Sheet" in layout.calls, "Expected <Sheet> to be an outgoing call"
      assert "SheetContent" in layout.calls, "Expected <SheetContent> to be an outgoing call"
    end

    test "lowercase HTML intrinsics are NOT in calls" do
      source = """
      export function Widget() {
        return (
          <div className="container">
            <span>hello</span>
            <Button />
          </div>
        );
      }
      """

      path = "/tmp/test_jsx_intrinsics_#{System.unique_integer()}.tsx"
      File.write!(path, source)
      on_exit(fn -> File.rm(path) end)

      {:ok, entities} = TreeSitterParser.parse_and_extract(path)
      widget = Enum.find(entities, &(&1.name == "Widget"))

      assert widget != nil, "Expected to find Widget component"
      refute "div" in widget.calls, "HTML intrinsic <div> should not be a call"
      refute "span" in widget.calls, "HTML intrinsic <span> should not be a call"
      assert "Button" in widget.calls, "PascalCase <Button /> should be a call"
    end
  end
end
