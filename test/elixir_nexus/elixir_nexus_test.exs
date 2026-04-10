defmodule ElixirNexusTest do
  use ExUnit.Case, async: true

  test "version/0 returns current version from mix.exs" do
    {:ok, contents} = File.read("mix.exs")
    [_, version] = Regex.run(~r/version:\s*"([^"]+)"/, contents)
    assert ElixirNexus.version() == version
  end
end
