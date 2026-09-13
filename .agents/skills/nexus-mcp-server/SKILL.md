---
name: nexus-mcp-server
description: ElixirNexus MCP server patterns — deftool DSL, key normalization, transport configuration, and numeric coercion. Use when adding or modifying MCP tools, debugging tool discovery, changing transport (stdio vs HTTP), or handling MCP protocol quirks with ex_mcp.
metadata:
  compatibility: ElixirNexus project only — lib/elixir_nexus/mcp_server.ex
---

# ElixirNexus MCP Server

## Key File

`lib/elixir_nexus/mcp_server.ex` — all MCP tool definitions and handlers.

## DSL → camelCase Normalization (Critical)

The `ex_mcp` DSL stores tool metadata with **atom keys** (`:input_schema`, `:display_name`), but the MCP spec requires **camelCase string keys** (`"inputSchema"`, `"displayName"`). Without normalization, clients can't discover tools.

`mcp_server.ex` overrides `get_tools/0` to fix this: it drops `:meta`/`:display_name` and renames `:input_schema` to `:inputSchema`. Read the override there rather than a copy here.

If you add a new tool and clients can't see it, check this normalization first.

## Numeric Parameter Coercion

MCP tool arguments arrive as **JSON strings** even for numeric parameters. Always use `to_int/2` for numeric `deftool` params:

```elixir
# In mcp_server.ex — to_int/2 helper
defp to_int(value, default) when is_binary(value) do
  case Integer.parse(value) do
    {int, _} -> int
    :error -> default
  end
end
defp to_int(value, _default) when is_integer(value), do: value
defp to_int(_, default), do: default

# Usage in tool handler
def handle_tool("search_code", %{"limit" => limit} = args, state) do
  limit = to_int(limit, 10)
  # ...
end
```

## Adding a New Tool

```elixir
deftool :my_tool do
  meta(
    display_name: "My Tool",
    description: "What this tool does"
  )

  input_schema(%{
    type: "object",
    properties: %{
      query: %{type: "string", description: "Search query"},
      limit: %{type: "integer", description: "Max results", default: 10}
    },
    required: ["query"]
  })
end

@impl true
def handle_tool("my_tool", %{"query" => query} = args, state) do
  limit = to_int(Map.get(args, "limit", "10"), 10)
  result = MyApp.do_work(query, limit)

  # Always use Jason.encode (not encode!) for safe serialization
  case Jason.encode(result) do
    {:ok, json} -> {:ok, json, state}
    {:error, _} -> {:error, "Serialization failed", state}
  end
end
```

## Transport: stdio vs HTTP

**stdio** — for local MCP clients (Claude Desktop, `mix mcp`):
```elixir
# mix mcp task suppresses all logging to preserve JSON-RPC protocol
Application.put_env(:logger, :level, :none)
Mix.shell(Mix.Shell.Quiet)
ElixirNexus.MCPServer.start(:stdio)
Process.sleep(:infinity)
```

**HTTP/Streamable** — for Docker deployments (`mix mcp_http --port 3002`):
```elixir
# When MCP_HTTP_PORT env is set, application.ex auto-starts HTTP server
# Both Phoenix :4100 and MCP :3002 run in a single BEAM instance
# They share ETS caches and PubSub — no sync delay
```

## Per-Request Server Instance (`start_link/1`)

ExMCP's HTTP transport handles **every request** by starting a temporary server with `start_link([])`, and ExMCP's default registers the global name `ElixirNexus.MCPServer`. That serialized the whole server: any concurrent request failed with `-32603 "Failed to start server instance"` / `{:already_started, pid}`. It happened on a client's parallel `tools/list` + `resources/list` at connect, with a second Claude Code session, and for everything during a long `reindex`. `start_link([])` is overridden to start unnamed; transport starts (`transport: :http`/`:stdio`) still go through `super`. The concurrency test in `protocol_compliance_test.exs` guards it.

## Resources Normalization

The DSL has the same problem for resources: every resource carries `size: nil`, `mime_type`, `list_pattern` and `meta`. A spec-validating client rejects the **whole** `resources/list` ("resources.N.size: Invalid input" in Claude Code's MCP log), so no resources load. `get_resources/0` is overridden to drop nil values and internal keys and rename `mime_type` to `mimeType`. Keep `subscribable`: ExMCP reads it to build the resources capability and crashes without it.

## Unknown Methods (`handle_request/3`)

ExMCP's default `handle_request/3` returns `{:noreply, state}` for any method it doesn't implement, and its HTTP plug turns that into **HTTP 500** "no response from handler". Claude Code sends a `server/discover` probe on connect (protocol 2026-07-28), so this fired on every connection. The override returns `:method_not_found` (becomes JSON-RPC `-32601`) but keeps `{:noreply, state}` for `notifications/*`, because ExMCP's notification cast path only matches that shape.

## Cowboy Options (`MCPServer.CowboyOptions`)

ExMCP starts Cowboy without protocol options, so `CowboyOptions.apply/0` sets them on the running listener through ranch, right after `start_link` in `application.ex` and `mix mcp_http`:

- `idle_timeout: :infinity`: Cowboy's 60s default counts only *incoming* data, so the SSE stream (`GET /mcp`), which only sends, was closed every 60s despite heartbeats. Claude Code logged "HTTP connection dropped after 60s uptime" and reconnected in a loop, and the tools kept disappearing.
- `max_header_value_length: 32_768`: Claude Code's headers exceed the 4096 default (HTTP 431). This used to be a `sed` patch in the Dockerfile.

## Verifying the Transport Against a Real Client

Tests run requests through `ExMCP.MessageProcessor` (`test/elixir_nexus/mcp_server/protocol_compliance_test.exs`), but connection-level bugs only show up on a live listener. After touching the transport, check the running server:

```bash
H=(-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream')
# unknown method: expect HTTP 200 with "code":-32601, not 500
curl -s -w ' %{http_code}\n' -X POST localhost:3002/mcp "${H[@]}" -d '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{}}'
# SSE stream: must stay open past 60s (heartbeat every 30s)
curl -sN --max-time 130 localhost:3002/mcp -H 'Accept: text/event-stream'
```

Claude Code's own MCP log is the ground truth for what the client rejected:
`~/Library/Caches/claude-cli-nodejs/<project-path-slug>/mcp-logs-code-nexus/*.jsonl`. Grep it for `dropped after`, `Invalid result`, and `Terminal connection error`.

## Timeout Patch

ExMCP's default tool call timeout is 10s — too short for `reindex`. The Dockerfile patches `message_processor.ex` via `sed` to raise it to 120s. If you hit timeout errors on `reindex`, check that Docker was rebuilt after code changes.

## handle_initialize

```elixir
@impl true
def handle_initialize(%{"rootUri" => "file://" <> path}, state) do
  # Extract project root from MCP client initialization
  # Store in state for auto-reindex on first query
  {:ok, capabilities(), %{state | project_root: path}}
end
```

## Auto-Reindex on Queries

All query tools (`search_code`, `find_all_callees`, etc.) call `maybe_reindex_dirty/1` before executing:

```elixir
defp maybe_reindex_dirty(state) do
  case state[:indexed_dirs] do
    nil -> state   # not yet indexed, skip
    dirs ->
      dirty = DirtyTracker.get_dirty_files_recursive(dirs)
      Enum.each(dirty, &Indexer.index_file/1)
      state
  end
end
```

This ensures queries always return fresh results without a manual `reindex`.
