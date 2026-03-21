defmodule Mix.Tasks.McpHttp do
  @moduledoc """
  Starts the ElixirNexus MCP server with HTTP/SSE transport.

  ## Usage

      mix mcp_http
      mix mcp_http --port 3001

  This starts the MCP server listening on HTTP for SSE connections,
  suitable for Docker deployments where stdio transport is not available.
  """

  use Mix.Task

  @shortdoc "Start MCP server over HTTP/SSE"

  @impl true
  def run(args) do
    port = parse_port(args)

    # MCP mode — skip auto-index
    Application.put_env(:elixir_nexus, :start_mcp_server, true)

    Application.ensure_all_started(:elixir_nexus)

    {:ok, _pid} = ElixirNexus.MCPServer.start_link(transport: :sse, port: port, host: "0.0.0.0")

    IO.puts("MCP HTTP server listening on port #{port}")

    # Block forever
    Process.sleep(:infinity)
  end

  defp parse_port(args) do
    case OptionParser.parse(args, strict: [port: :integer]) do
      {opts, _, _} -> Keyword.get(opts, :port, 3001)
      _ -> 3001
    end
  end
end
