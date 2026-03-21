defmodule Mix.Tasks.McpHttpTest do
  use ExUnit.Case, async: true

  test "module exists" do
    assert Code.ensure_loaded?(Mix.Tasks.McpHttp)
  end

  test "has run/1 function" do
    Code.ensure_loaded!(Mix.Tasks.McpHttp)
    assert function_exported?(Mix.Tasks.McpHttp, :run, 1)
  end
end
