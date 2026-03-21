defmodule ElixirNexus.ErrorHTMLTest do
  use ExUnit.Case, async: true

  alias ElixirNexus.ErrorHTML

  test "renders 500 page" do
    result = ErrorHTML.render("500.html", %{})
    assert is_binary(result)
  end

  test "renders 404 page" do
    result = ErrorHTML.render("404.html", %{})
    assert is_binary(result)
  end
end
