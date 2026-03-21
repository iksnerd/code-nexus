defmodule Mix.Tasks.IndexTest do
  use ExUnit.Case, async: true

  test "module exists" do
    assert Code.ensure_loaded?(Mix.Tasks.Index)
  end

  test "has run/1 function" do
    Code.ensure_loaded!(Mix.Tasks.Index)
    assert function_exported?(Mix.Tasks.Index, :run, 1)
  end

  test "has correct shortdoc" do
    assert Mix.Task.shortdoc(Mix.Tasks.Index) =~ "Index"
  end
end
