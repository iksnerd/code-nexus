defmodule ElixirNexus.MCPServer.CowboyOptions do
  @moduledoc """
  Cowboy settings for the MCP HTTP listener that ExMCP 0.9 doesn't expose.

  ExMCP starts the listener through `Plug.Cowboy.http/3` without protocol
  options, so they're applied to the running listener through ranch instead.
  Ranch applies new protocol options to connections accepted afterwards, so
  call `apply/1` right after the server starts.
  """

  # Plug.Cowboy's default listener ref for ExMCP.HttpPlug over plain HTTP.
  @default_ref ExMCP.HttpPlug.HTTP

  @overrides %{
    # Cowboy closes a connection after 60s without incoming data. The MCP SSE
    # stream (GET /mcp) only ever sends, so clients were disconnected every
    # minute despite the 30s heartbeats.
    idle_timeout: :infinity,
    # Claude Code sends header values over Cowboy's 4096-byte default, which
    # Cowboy rejects with HTTP 431.
    max_header_value_length: 32_768
  }

  @doc "Merge the overrides into the listener's current protocol options."
  def apply(ref \\ @default_ref) do
    :ranch.set_protocol_options(ref, Map.merge(:ranch.get_protocol_options(ref), @overrides))
  end
end
