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
end
