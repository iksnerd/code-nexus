# CodeNexus

Code intelligence MCP server — graph-powered semantic search, call graph traversal, and impact analysis for any codebase. Built for AI agents (Claude Code, Cursor, etc.) via the Model Context Protocol.

## Quick Start

**Prerequisites:** Ollama running on the host with `nomic-embed-text` pulled (`ollama pull nomic-embed-text`).

```bash
WORKSPACE=~/Documents docker-compose up -d
```

This starts CodeNexus (Phoenix dashboard on `:4100`, MCP Streamable HTTP on `:3002`) and Qdrant (vector DB on `:6333`). The container reaches Ollama on the host via `host.docker.internal:11434`.

### Without docker-compose

```bash
docker run -d --name qdrant -p 6333:6333 qdrant/qdrant:latest

docker run -d --name elixir_nexus \
  -p 4100:4100 -p 3002:3002 \
  -e QDRANT_URL=http://host.docker.internal:6333 \
  -e MCP_HTTP_PORT=3002 \
  -e OLLAMA_URL=http://host.docker.internal:11434 \
  -e WORKSPACE_HOST="$HOME/Documents" \
  -v "$HOME/Documents:/workspace:ro" \
  iksnerd/elixir-nexus:latest
```

## Workspace Mount

Mount a host directory at `/workspace` to make your projects indexable:

```bash
WORKSPACE=~/Documents docker-compose up -d
```

The `reindex` MCP tool resolves paths flexibly:

| Input | Resolves to |
|-------|------------|
| `"my-project"` | `/workspace/my-project` |
| `"/Users/you/Documents/my-project"` | `/workspace/my-project` (auto-translated) |
| `"/workspace/my-project"` | `/workspace/my-project` (passthrough) |
| _(omitted)_ | `/app` (CodeNexus itself) |

If a project isn't found, the error lists all available projects in `/workspace`.

## MCP Tools

| Tool | Description |
|------|-------------|
| `reindex` | Parse source files, build search index and call graph |
| `search_code` | Hybrid semantic + keyword search with graph-boosted ranking |
| `find_all_callees` | Find all functions called by a given function |
| `find_all_callers` | Find all callers of a function (calls + imports) |
| `analyze_impact` | Transitive blast radius — callers-of-callers AND importers |
| `get_community_context` | Find structurally coupled files via call graph and import edges |
| `find_module_hierarchy` | Module parents (uses/implements) and children |
| `find_dead_code` | Find exported functions with zero callers |
| `get_graph_stats` | Structural overview with critical files (betweenness centrality) |

## Supported Languages

Elixir, JavaScript, TypeScript, TSX, Python, Go, Rust, Java.

## Claude Code MCP Config

Add to your project's `.mcp.json`:

```json
{
  "mcpServers": {
    "elixir-nexus": {
      "type": "http",
      "url": "http://localhost:3002/mcp"
    }
  }
}
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `QDRANT_URL` | `http://localhost:6333` | Qdrant vector DB URL |
| `MCP_HTTP_PORT` | _(unset)_ | Set to enable MCP Streamable HTTP transport |
| `OLLAMA_URL` | `http://localhost:11434` | Ollama API URL (use `http://host.docker.internal:11434` in Docker) |
| `WORKSPACE_HOST` | _(unset)_ | Host path mounted at `/workspace` (for path translation) |
| `WORKSPACE` | _(unset)_ | docker-compose: host dir to mount at `/workspace` |

## Architecture

- **Elixir/Phoenix** app with Broadway-based indexing pipeline
- **Tree-sitter** (Rust NIF) for AST parsing across all supported languages
- **Ollama nomic-embed-text** for 768-dim dense semantic embeddings
- **TF-IDF** sparse vectors with ETS-backed vocabulary for hybrid search
- **Qdrant** for vector storage and hybrid search (RRF fusion)
- **ExMCP** for MCP protocol (stdio + Streamable HTTP)

## Source

[github.com/iksnerd/elixir-nexus](https://github.com/iksnerd/elixir-nexus)
