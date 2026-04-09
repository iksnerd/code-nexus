defmodule Mix.Tasks.Mcp do
  @moduledoc """
  Starts the ElixirNexus MCP server with stdio transport.

  ## Usage

      mix mcp

  This starts the MCP server listening on stdin/stdout for JSON-RPC messages,
  suitable for use with Claude Code and other MCP-compatible clients.
  """

  use Mix.Task

  @shortdoc "Start MCP server over stdio"

  @impl true
  def run(_args) do
    # Suppress all console logging — MCP uses stdout exclusively for JSON-RPC
    # Any log output to stdout corrupts the JSON-RPC protocol
    Application.put_env(:logger, :level, :none)
    Logger.configure(level: :none)
    Mix.shell(Mix.Shell.Quiet)

    # Skip auto-index on boot — MCP uses the reindex tool explicitly
    Application.put_env(:elixir_nexus, :start_mcp_server, true)

    Application.ensure_all_started(:elixir_nexus)

    {:ok, _pid} = ElixirNexus.MCPServer.start_link(transport: :stdio)

    # Block forever — the server runs until the process is killed
    Process.sleep(:infinity)
  end
end
