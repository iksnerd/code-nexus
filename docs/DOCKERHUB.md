# CodeNexus

Code intelligence MCP server — graph-powered semantic search, call graph traversal, and impact analysis for any codebase. Built for AI agents (Claude Code, Cursor, etc.) via the Model Context Protocol.

## Quick Start

**Prerequisites:** Ollama running on the host with `embeddinggemma:300m` pulled (`ollama pull embeddinggemma:300m`). Alternative: set `OLLAMA_MODEL=nomic-embed-text` and pull that model instead (lighter, faster on CPU).

```bash
WORKSPACE=~/Documents docker-compose up -d
```

This starts CodeNexus (Phoenix dashboard on `:4100`, MCP Streamable HTTP on `:3002`) and Qdrant (vector DB on `:6333`). The container reaches Ollama on the host via `host.docker.internal:11434`.

### Without docker-compose

```bash
docker run -d --name qdrant -p 6333:6333 qdrant/qdrant:latest

docker run -d --name code_nexus \
  -p 4100:4100 -p 3002:3002 \
  -e QDRANT_URL=http://host.docker.internal:6333 \
  -e MCP_HTTP_PORT=3002 \
  -e OLLAMA_URL=http://host.docker.internal:11434 \
  -e WORKSPACE_HOST="$HOME/Documents" \
  -e WORKSPACE_HOST_2="$HOME/GolandProjects" \
  -v "$HOME/Documents:/workspace:ro" \
  -v "$HOME/GolandProjects:/workspace2:ro" \
  iksnerd/code-nexus:latest
```

## Workspace Mount

Mount a host directory at `/workspace` to make your projects indexable:

```bash
WORKSPACE=~/Documents docker-compose up -d
```

Projects scattered across multiple directories? Add up to two more mounts:

```bash
WORKSPACE=~/Documents WORKSPACE_HOST=~/Documents \
WORKSPACE_2=~/GolandProjects WORKSPACE_HOST_2=~/GolandProjects \
docker-compose up -d
```

`WORKSPACE_HOST` / `WORKSPACE_HOST_2` / `WORKSPACE_HOST_3` tell the MCP server which host path maps to each container mount, enabling automatic path translation.

The `reindex` MCP tool resolves bare project names across all active mounts:

| Input | Resolves to |
|-------|------------|
| `"my-project"` | first mount where `/workspaceN/my-project` exists |
| `"/Users/you/Documents/my-project"` | `/workspace/my-project` (auto-translated) |
| `"/workspace/my-project"` | `/workspace/my-project` (passthrough) |
| _(omitted)_ | `/app` (CodeNexus itself) |

If a project isn't found, the error lists all available projects across all mounts.

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
| `get_graph_stats` | Structural overview with critical files (betweenness centrality) and current `project_path` |

## Supported Languages

Elixir, JavaScript, TypeScript, TSX, Python, Go, Rust, Java.

## Claude Code MCP Config

Add to your project's `.mcp.json`:

```json
{
  "mcpServers": {
    "code-nexus": {
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
| `OLLAMA_MODEL` | `embeddinggemma:300m` | Ollama embedding model name (768-dim) |
| `WORKSPACE_HOST` | _(unset)_ | Host path mapped to `/workspace` (for path translation) |
| `WORKSPACE_HOST_2` | _(unset)_ | Host path mapped to `/workspace2` |
| `WORKSPACE_HOST_3` | _(unset)_ | Host path mapped to `/workspace3` |
| `WORKSPACE_HOST_4` | _(unset)_ | Host path mapped to `/workspace4` |
| `WORKSPACE_HOST_5` | _(unset)_ | Host path mapped to `/workspace5` |
| `WORKSPACE` | _(unset)_ | docker-compose: host dir to mount at `/workspace` |
| `WORKSPACE_2` | _(unset)_ | docker-compose: host dir to mount at `/workspace2` |
| `WORKSPACE_3` | _(unset)_ | docker-compose: host dir to mount at `/workspace3` |
| `WORKSPACE_4` | _(unset)_ | docker-compose: host dir to mount at `/workspace4` |
| `WORKSPACE_5` | _(unset)_ | docker-compose: host dir to mount at `/workspace5` |

## Architecture

- **Elixir/Phoenix** app with Broadway-based indexing pipeline
- **Tree-sitter** (Rust NIF) for AST parsing across all supported languages
- **Ollama embeddinggemma:300m** for 768-dim dense semantic embeddings (configurable via `OLLAMA_MODEL`)
- **TF-IDF** sparse vectors with ETS-backed vocabulary for hybrid search
- **Qdrant** for vector storage and hybrid search (RRF fusion)
- **ExMCP** for MCP protocol (stdio + Streamable HTTP)

## Image Size

The runtime image is **~588MB** (multi-stage build — Rust toolchain is build-only).

## Tags

- `latest` — current release (v1.4.2)
- `v1.4.2` — Dockerfile: `MIX_ENV=prod` build + `mix phx.digest`; fixes missing static manifest on prod image startup
- `v1.4.1` — block `/app` indexing in Docker mode, filter test collections from UI, Go dead-code false-positive fix, skill bundling tests
- `v1.4.0` — Prometheus metrics at `GET /metrics` (search latency, indexing throughput, Qdrant ops, BEAM VM stats)
- `v1.3.5` — OSS prep: untrack Rust build artifacts, `MIX_ENV: prod` in docker-compose, fix `.claude/skills` symlink; docs cleanup; CI fix for test collection race condition
- `v1.3.4` — fix skills wiped at runtime by dev-mode code reload; `MIX_ENV: prod` in docker-compose
- `v1.3.1` — restrict MCP-exposed skills to user-facing client guides; three new client skills (search recipes, refactoring workflow, onboarding)
- `v1.3.0` — skills exposed as MCP resources (`nexus://skill/<name>`), embedded at compile time
- `v1.2.9` — image catch-up release (rolls up v1.2.8 fixes)
- `v1.2.7` — add Go convention dirs (`cmd/`, `internal/`, `pkg/`) to source detection
- `v1.2.5` — monorepo source-dir detection (depth-2 fallback for multi-subproject repos)
- `v1.2.2` — single-project workspace mounts; workspace slots extended to 5
- `v1.2.0` — default model switched to `embeddinggemma:300m`; fix concurrency race in collection switch; fix cold-start Ollama timeouts
- `v1.1.0` — multi-workspace Docker mounts (`WORKSPACE_2`/`WORKSPACE_3`), bare project name resolution across all mounts
- `v1.0.5` — fix Qdrant test collection leak, test splits, qdrant_client.ex reorganisation, 20 new QdrantClient tests (725 total)
- `v1.0.4` — fix dashboard broken LiveView (missing vendor JS in Docker), static asset tests, graph page tests, test collection cleanup
- `v1.0.3` — rename container `elixir_nexus` → `code_nexus`
- `v1.0.2` — fix `load_resources` entity type display, 13 new resource tests
- `v1.0.1` — internal refactor: split large source/test files into focused modules
- `v1.0.0` — server renamed to `code-nexus`, directive metadata, tsconfig alias resolution, `OLLAMA_MODEL` env var, graph noise filter extended
- `v0.9.0` — MCP resources, `load_resources` fallback tool, dynamic codebase knowledge
- `v0.8.0` — concurrent reads, caller refinement, fuzzy callees, `@/` alias resolution
- `v0.7.1` — Qdrant test collection cleanup
- `v0.7.0` — skills-based review fixes, Broadway error handling, ETS crash safety
- `v0.6.0` — CI fixes, callers line info, project_path tracking, Docker multi-stage build (588MB)
- `v0.5.0` — D3 graph visualization, README overhaul
- `v0.4.0` — JSX call edges, dead code convention filter, graph noise filter
- `v0.3.0` — file_path resolution, centrality scoring, dead code conventions
- `v0.2.0` — CI/CD, Streamable HTTP, Ollama embeddings, Go support

## Source

[github.com/iksnerd/code-nexus](https://github.com/iksnerd/code-nexus)
