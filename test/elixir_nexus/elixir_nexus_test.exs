defmodule ElixirNexusTest do
  use ExUnit.Case, async: true

  test "version/0 returns current version from VERSION file" do
    version = File.read!("VERSION") |> String.trim()
    assert ElixirNexus.version() == version
  end
end
