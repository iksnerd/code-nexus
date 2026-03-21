defmodule Mix.Tasks.McpTest do
  use ExUnit.Case, async: true

  test "module exists" do
    assert Code.ensure_loaded?(Mix.Tasks.Mcp)
  end

  test "has run/1 function" do
    Code.ensure_loaded!(Mix.Tasks.Mcp)
    assert function_exported?(Mix.Tasks.Mcp, :run, 1)
  end
end
