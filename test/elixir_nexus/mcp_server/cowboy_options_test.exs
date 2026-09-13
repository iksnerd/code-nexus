defmodule ElixirNexus.MCPServer.CowboyOptionsTest do
  use ExUnit.Case, async: false

  alias ElixirNexus.MCPServer.CowboyOptions

  setup do
    ref = :"cowboy_options_test_#{System.unique_integer([:positive])}"

    {:ok, _} =
      Plug.Cowboy.http(ExMCP.HttpPlug, [handler: ElixirNexus.MCPServer, server_info: %{}, tools: []],
        port: 0,
        ref: ref
      )

    on_exit(fn -> Plug.Cowboy.shutdown(ref) end)
    {:ok, ref: ref, port: :ranch.get_port(ref)}
  end

  test "disables the idle timeout and raises the header limit", %{ref: ref} do
    before = :ranch.get_protocol_options(ref)

    :ok = CowboyOptions.apply(ref)
    opts = :ranch.get_protocol_options(ref)

    assert opts.idle_timeout == :infinity
    assert opts.max_header_value_length == 32_768
    # Keeps what Plug.Cowboy configured (the dispatch env).
    assert opts.env == before.env
  end

  test "a header over Cowboy's 4096-byte default is accepted after apply", %{ref: ref, port: port} do
    :ok = CowboyOptions.apply(ref)

    {:ok, %HTTPoison.Response{status_code: status}} =
      HTTPoison.get("http://127.0.0.1:#{port}/.well-known/oauth-protected-resource", [
        {"x-large", String.duplicate("a", 8_000)}
      ])

    refute status == 431
  end
end
