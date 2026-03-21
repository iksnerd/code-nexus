defmodule ElixirNexus.ErrorJSONTest do
  use ExUnit.Case, async: true

  alias ElixirNexus.ErrorJSON

  test "renders 404.json" do
    result = ErrorJSON.render("404.json", %{})
    assert %{errors: %{detail: _}} = result
  end

  test "renders 500.json" do
    result = ErrorJSON.render("500.json", %{})
    assert %{errors: %{detail: _}} = result
  end
end
