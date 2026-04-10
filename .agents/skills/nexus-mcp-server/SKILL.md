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

`mcp_server.ex` overrides `get_tools/0` to fix this:

```elixir
@impl true
def get_tools() do
  super()
  |> Enum.map(fn tool ->
    tool
    |> Map.new(fn
      {:input_schema, v} -> {"inputSchema", v}
      {:display_name, v} -> {"displayName", v}
      {k, v} -> {Atom.to_string(k), v}
    end)
  end)
end
```

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
