defmodule ElixirNexusTest do
  use ExUnit.Case, async: true

  test "version/0 returns current version" do
    assert ElixirNexus.version() == "0.1.0"
  end
end
