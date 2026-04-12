<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="code-nexus.svg" />
    <source media="(prefers-color-scheme: light)" srcset="docs/logo-dark.svg" />
    <img src="docs/logo-dark.svg" width="80" alt="CodeNexus logo" />
  </picture>
</p>

<h1 align="center">CodeNexus</h1>

<p align="center">Code intelligence MCP server — graph-powered semantic search, call graph traversal, and impact analysis for any codebase.</p>

Built on Elixir/OTP with Ollama for dense embeddings, Qdrant for hybrid vector + keyword search (RRF fusion), and Sourceror/Tree-sitter for polyglot AST parsing. Designed for large codebases with live incremental indexing.

![Dashboard](docs/screenshots/dashboard.png)

## Quick Start

```bash
# Start Qdrant + CodeNexus with access to your projects
WORKSPACE=~/projects docker-compose up -d

# Or pull the pre-built image first
docker pull iksnerd/code-nexus:latest
WORKSPACE=~/projects docker-compose up -d
```

`WORKSPACE` sets which host directory CodeNexus can read for indexing. It's mounted read-only at `/workspace` inside the container. MCP `reindex(path)` accepts host paths (e.g. `~/projects/my-app`) — they're automatically translated to container paths.

Without `WORKSPACE`, only the CodeNexus repo itself (`/app`) is indexable.

This starts three services in a single BEAM instance:

| Service | Port | Purpose |
|---------|------|---------|
| Phoenix Dashboard | `localhost:4100` | Web UI for search, vectors, stats |
| MCP HTTP Server | `localhost:3002` | MCP tools for AI agents |
| Qdrant | `localhost:6333` | Vector database |

**Connect Claude Code** — add to your project's `.mcp.json`:

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

### Indexing

```bash
# Via MCP tool (recommended — Claude Code calls this automatically)
# Use the reindex tool in Claude Code

# Via CLI
mix index /path/to/code
mix index /path/to/file.ex
mix index --status
```

### Local Development

For building and testing CodeNexus itself:

```bash
docker-compose up -d qdrant   # Qdrant only
mix deps.get
mix phx.server                # Phoenix dashboard on :4100
mix mcp                       # MCP stdio transport
mix mcp_http --port 3001      # MCP HTTP transport
```

## Architecture

```mermaid
graph TB
    subgraph Sources["Source Files"]
        EX[".ex / .exs"]
        JS[".js / .ts / .tsx"]
        PY[".py"]
        OTHER[".go / .rs / .java"]
    end

    subgraph Parsing["Parsing Layer"]
        SR["Sourceror<br/>(Elixir AST)"]
        TS["Tree-sitter NIF<br/>(Rust, polyglot)"]
    end

    subgraph Extractors["Language Extractors"]
        RE["RelationshipExtractor<br/>Elixir"]
        JSE["JavaScriptExtractor<br/>JS/TS imports, exports, calls"]
        PYE["PythonExtractor<br/>imports, decorators, calls"]
        GOE["GoExtractor<br/>calls, imports, structs"]
        GE["GenericExtractor<br/>Rust, Java"]
    end

    subgraph Indexing["Indexing Pipeline (Broadway)"]
        CH["Chunker<br/>semantic chunks"]
        OL["Ollama nomic-embed-text<br/>768-dim dense vectors"]
        TFIDF["TF-IDF<br/>sparse keyword vectors"]
    end

    subgraph Storage["Storage Layer"]
        QD["Qdrant<br/>hybrid search (RRF)"]
        CC["ChunkCache (ETS)<br/>O(1) chunk lookups"]
        GC["GraphCache (ETS)<br/>call graph + relationships"]
    end

    subgraph API["API Layer"]
        MCP_HTTP["MCP Server (HTTP)<br/>Streamable HTTP"]
        REST["REST API"]
        PHX["Phoenix LiveView<br/>Dashboard"]
    end

    EX --> SR --> RE
    JS --> TS --> JSE
    PY --> TS --> PYE
    OTHER --> TS --> GOE & GE

    RE & JSE & PYE & GOE & GE --> CH
    CH --> OL & TFIDF
    OL & TFIDF --> QD
    CH --> CC --> GC

    QD & GC --> MCP_HTTP & REST & PHX
```

### Search Pipeline

```mermaid
graph LR
    Q["Query"] --> DE["Dense Embedding<br/>Ollama"]
    Q --> SE["Sparse Vector<br/>TF-IDF"]
    DE & SE --> HQ["Qdrant Hybrid Query<br/>RRF Fusion"]
    HQ --> DD["Dedup<br/>name + type"]
    DD --> GR["Graph Re-ranking<br/>call graph boost"]
    GR --> R["Results"]
```

1. **Dense embedding** via Ollama nomic-embed-text (falls back to TF-IDF)
2. **Sparse keyword vector** via TF-IDF feature hashing
3. **Qdrant hybrid query** with prefetch + RRF fusion (server-side)
4. **Deduplication** by name + entity type
5. **Graph re-ranking** using relationship boost from call graph
6. **Filter & limit** (remove temp files, sort by score)

### Deployment

```mermaid
graph TB
    subgraph Docker["Docker (docker-compose up)"]
        direction LR
        PHX_D["Phoenix :4100"]
        MCP_D["MCP HTTP :3002"]
        PHX_D & MCP_D --- BEAM_D["Single BEAM Instance"]
        BEAM_D --- QD_D["Qdrant :6333"]
    end

    CC_D["Claude Code<br/>url: localhost:3002/mcp"] --> MCP_D
```

### Supervision Tree

```mermaid
graph TD
    SUP["ElixirNexus.Supervisor<br/>(rest_for_one)"]
    SUP --> PS["PubSub"]
    SUP --> DT["DirtyTracker"]
    SUP --> TF["TFIDFEmbedder"]
    SUP --> QC["QdrantClient"]
    SUP --> REG["Registry"]
    SUP --> CO["CacheOwner<br/>(ETS tables)"]
    SUP --> IDX["Indexer"]
    SUP --> IP["IndexingPipeline<br/>(Broadway)"]
    SUP --> EP["Phoenix Endpoint"]
    SUP --> FW["FileWatcher"]
    SUP --> TS["TaskSupervisor"]
```

Strategy: `rest_for_one` — if a dependency crashes, all processes started after it restart. This ensures the Indexer restarts when CacheOwner or QdrantClient crash.

## MCP Tools

Nine tools for AI agents (Claude Code, Claude Desktop, Cursor, etc.):

| Tool | Description |
|------|-------------|
| **search_code**(query, limit) | Hybrid semantic + keyword search, ranked by vector similarity and graph centrality |
| **find_all_callees**(entity_name, limit) | Find all functions called by a given function |
| **find_all_callers**(entity_name, limit) | Find all callers of a function — follows both call edges and import references |
| **analyze_impact**(entity_name, depth) | Transitive blast radius — walks callers-of-callers AND importers up to `depth` levels |
| **get_community_context**(file_path, limit) | Discover structurally coupled files via call-graph and import edges (bidirectional) |
| **get_graph_stats**() | Codebase overview: node counts, edge counts, entity types, languages, top connected, critical files (betweenness centrality) |
| **find_module_hierarchy**(entity_name) | Module parents (behaviours/uses) and children — supports file-path and substring matching for TS/React components |
| **find_dead_code**(path_prefix) | Find exported functions/methods with zero callers — proactively flag unused code |
| **reindex**(path) | Parse and index source files to build the search index and call graph |

### Transport

MCP is served over HTTP (Streamable HTTP at `/mcp`) via Docker. For local development, stdio (`mix mcp`) is also available.

## REST API

### Search & Discovery

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/search` | Hybrid semantic + keyword search |
| POST | `/api/callees` | Find callees of a function |
| POST | `/api/index` | Trigger indexing |

### Vector Management

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/vectors/info` | Collection metadata |
| GET | `/api/vectors/count` | Point count |
| POST | `/api/vectors/scroll` | Paginated point listing |
| GET | `/api/vectors/:id` | Get a single point |
| POST | `/api/vectors/delete` | Delete points by ID |
| POST | `/api/vectors/reset` | Reset the collection |

## Polyglot Support

Elixir files are parsed via Sourceror (richer metadata). Other languages use Tree-sitter via a Rustler NIF, with language-specific extractors:

| Language | Extension | Parser | Extractor |
|----------|-----------|--------|-----------|
| Elixir | `.ex`, `.exs` | Sourceror | RelationshipExtractor |
| JavaScript | `.js`, `.jsx` | Tree-sitter | JavaScriptExtractor |
| TypeScript | `.ts`, `.tsx` | Tree-sitter | JavaScriptExtractor |
| Python | `.py` | Tree-sitter | PythonExtractor |
| Go | `.go` | Tree-sitter | GoExtractor |
| Ruby | `.rb` | Tree-sitter | GenericExtractor |
| Rust | `.rs` | Tree-sitter | GenericExtractor |
| Java | `.java` | Tree-sitter | GenericExtractor |

**Extractor capabilities:**

| Feature | JS/TS | Python | Go | Generic |
|---------|-------|--------|----|---------|
| Functions/classes/methods | Y | Y | Y | Y |
| Import extraction | Y | Y | Y | Y |
| Export extraction | Y | - | - | - |
| Decorator extraction | - | Y | - | - |
| Call graph | Y | Y | Y | Y |
| Package-qualified calls | Y | - | Y | - |
| Receiver methods | - | - | Y | - |
| Struct/interface extraction | - | - | Y | - |
| Arrow function classification | Y | - | - | - |
| Barrel file resolution | Y | - | - | - |
| Visibility (Go uppercase convention) | - | - | Y | - |
| Visibility (_private convention) | - | Y | - | - |

Tree-sitter support requires the Rust toolchain. Without it, only Elixir files are indexed.

### Embedding Strategy

| Vector Type | Model | Purpose |
|-------------|-------|---------|
| Dense (768-dim) | `nomic-embed-text` via Ollama | Semantic similarity |
| Sparse | TF-IDF feature hashing (ETS-backed IDF) | Keyword/exact match |
| Fusion | Qdrant RRF | Combines both server-side |

## Web Dashboard

Phoenix LiveView UI at `http://localhost:4100`:

- **Dashboard** — Indexing statistics, entity/edge counts, language distribution, top connected modules, MCP tool reference. Auto-syncs from Qdrant when MCP reindexes externally.
- **Search** — Interactive hybrid search with scored results, entity badges, code preview, call/is_a tags.
- **Graph** — Interactive D3.js force-directed graph showing code relationships. Three edge types (calls, imports, contains) with distinct visual styles. Hover to highlight connected nodes and see detailed metadata.
- **Vectors** — Browse, filter, inspect, and manage stored vectors.

### Search

![Search](docs/screenshots/search.png)

### Graph Visualization

![Graph](docs/screenshots/graph.png)

The graph renders up to 500 nodes sorted by connectivity. Hover any node to highlight its neighbors and see file path, line range, calls, and imports in the detail panel. Zoom, pan, and drag nodes to explore.

### Vectors

![Vectors](docs/screenshots/vectors.png)

## Testing

```bash
mix test                        # All tests (~707)
mix test --trace                # Verbose output
mix test --include performance  # Performance benchmarks (32 tests)
mix test test/elixir_nexus/parsers/  # Parser tests
```

## Performance Benchmarks

Run with `mix test --include performance`:

| Operation | Latency | Scale |
|-----------|---------|-------|
| ETS insert 10K chunks | 4ms | |
| ETS search 10K chunks | 13ms | |
| ETS 100 concurrent searches (p99) | 53ms | 10K chunks |
| Graph rebuild | 458ms | 1K chunks |
| Ollama single embed | 29ms | 768-dim |
| TF-IDF single embed | 0.09ms | 768-dim (~456x faster) |
| Hybrid search e2e (p50) | 21ms | |
| analyze_impact | 3.5ms | 500 entities |
| get_community_context | 1.2ms | 500 entities |
| Index 20 files (Broadway) | 2.0s | |
| PubSub 100 subscribers | 0.17ms max | |

## Changelog

### v1.0.5
- **Fix Qdrant test collection leak** — cleanup in 3 MCP server reindex tests moved to `on_exit` so it runs even on test failure; deleted 19 previously accumulated orphan collections
- **Test splits** — `mcp_server_test.exs`, `relationship_graph_test.exs`, `indexer_test.exs` split into 8 focused files, completing the test reorganisation series
- **`qdrant_client.ex` internal reorganisation** — sections reordered into clear domains: configuration, GenServer lifecycle, collection management, search (read-only), point reads, point writes, callbacks, HTTP helpers
- **QdrantClient tests** — 20 new tests covering `collection_name/0` derivation logic, `active_collection/0` Application env reads, process dict override, and `switch_collection_force/1`; collection management functions now have coverage
- 725 tests total

### v1.0.4
- **Fix dashboard broken LiveView** — vendor JS files (`phoenix.min.js`, `phoenix_live_view.min.js`) were not tracked in git, so Docker builds excluded them. All LiveView interactivity (buttons, graph, search) was broken in Docker mode.
- **Static asset tests** — new `static_assets_test.exs` verifies vendor JS and image files are served with 200
- **Graph page tests** — new `graph_live_test.exs` covers mount, refresh, collection switch, and event handling
- **Test collection cleanup** — `ExUnit.after_suite` now deletes the test Qdrant collection after each test run
- 707 tests total

### v1.0.3
- Rename container name `elixir_nexus` → `code_nexus` in docker-compose and Makefile

### v1.0.2
- **Fix `load_resources` entity types showing as `"unknown"`** — `nexus://project/overview`, `nexus://project/architecture`, and `nexus://project/hotspots` now correctly read `node["entity_type"] || node["type"]`, matching the key used by `RelationshipGraph.build_graph/1`
- **13 new tests for `MCPServer.Resources`** — overview, architecture, hotspots, and not-indexed message paths now directly covered

### v1.0.1
- **Internal refactor** — split 4 large source files (`search/queries.ex`, `mcp_server.ex`, `javascript_extractor.ex`, `go_extractor.ex`) into focused domain sub-modules; all public APIs unchanged
- **Test reorganisation** — 5 large test files split into 23 focused test files, matching source module boundaries
- **Direct unit tests for `EntityResolution` and `PathResolution`** — `matches_entity_name?/2`, `import_matches_file?/2`, `find_entity_multi_strategy/2`, and `PathResolution` pure functions now have dedicated test coverage
- 714 tests total, 0 failures

### v1.0.0
- **Server renamed to `code-nexus`** — MCP server name updated for discoverability by JS/TS/Go/Python users
- **`"use client"` / `"use server"` directive indexing** — Next.js directives tagged as `directive:use-client` / `directive:use-server` metadata on file-level entities; improves search precision on full-stack codebases
- **tsconfig path alias resolution** — `find_module_hierarchy` now reads `tsconfig.json` `compilerOptions.paths` to resolve `@/*` → `src/*` style aliases accurately
- **`OLLAMA_MODEL` env var** — embedding model is now configurable via `OLLAMA_MODEL` (default: `nomic-embed-text`)
- **Reindex default-path warning** — when no `path` is given in local/no-workspace mode and no project has been indexed yet, result includes a `warning` key
- **Extended graph noise filter** — `get_graph_stats` top-connected now filters short PascalCase wrapper names (`Comp`, `Box`, `Row`, etc.) and common React utility names (`createContext`, `memo`, `Fragment`, etc.)
- **GitHub topics** — `mcp`, `code-intelligence`, `elixir`, `tree-sitter`, `qdrant`, `semantic-search`
- **3 new project-switching tests** — nonexistent collection, rapid successive switches, switch-while-idle

### v0.9.0
- **MCP Resources** — expose codebase knowledge as MCP resources (`nexus://guide/tools`, `nexus://project/overview`, `nexus://project/architecture`, `nexus://project/hotspots`) for resource-aware clients
- **`load_resources` fallback tool** — list or read resources from clients that only support tools (follows MCP creator's recommended pattern)
- Dynamic resources generated from ETS caches (ChunkCache, GraphCache) — no Qdrant calls needed

### v0.8.0
- **Concurrent QdrantClient reads** — cross-project isolation, process dictionary collection pinning
- **Caller refinement** — callers now resolve to enclosing function, not module
- **Fuzzy callees** — short name matching for `find_all_callees`
- **`@/` path alias resolution** — JS/TS `@/components/...` imports resolved to actual entities
- **Reindex warning** — omitting `path` when workspace projects exist now returns an error instead of silently indexing `/app`

### v0.7.1
- **Qdrant test collection cleanup** — deleted 84 orphaned test collections, added `QdrantClient.delete_collection/1` by name, fixed test cleanup to prevent future accumulation

### v0.7.0
- **Broadway error handling** — parse failures now properly use `Broadway.Message.failed/2` instead of silently swallowing errors
- **TFIDFEmbedder ETS crash-safe** — IDF table moved to CacheOwner (survives TFIDFEmbedder crashes)
- **Deduplicated indexing handlers** — extracted `prepare_reindex/1` and `do_index_files/3`
- **`is_dirty?/1` → `dirty?/1`** — renamed to follow Elixir naming convention
- **Single source of truth for extensions** — `DirtyTracker` now delegates to `IndexingHelpers.all_indexable_extensions/0`
- **`search_chunks/2` optimization** — removed GenServer bottleneck, calls ETS directly
- **ChunkCache.search performance** — replaced O(n) `length/1` with O(1) counter accumulator in foldl
- **Node structure consistency** — `update_file/2` now uses `"entity_type"` matching `rebuild_from_chunks/1`
- **15 Agent Skills** — `.agents/skills/` with 10 general Elixir/OTP/Phoenix skills + 5 project-specific skills (agentskills.io standard)
- 640 tests (7 new)

### v0.6.0
- **CI fixed** — NIF and file watcher tests now correctly excluded in CI; version assertion no longer hardcoded
- **`find_all_callers` line numbers** — `start_line`/`end_line` now populated with real function positions (was always 0)
- **`get_graph_stats` includes `project_path`** — survives MCP server restarts so callers can detect stale index
- **Docker image 588MB** (was 3.28GB) — multi-stage build drops Rust toolchain from runtime; added `.dockerignore`
- 12 new tests (633 total)

### v0.5.0
- D3 force-directed graph at `/graph` — 3 edge types, hover highlighting, glow rings, 500-node cap
- README overhaul with fresh benchmarks and dashboard screenshots

### v0.4.0
- JSX component renders tracked as call edges in `find_all_callees`
- `find_dead_code` filters framework conventions (Next.js pages, layouts, route handlers, loading)
- Framework utility noise (`cn`, `Comp`, `Slot`) filtered from `get_graph_stats` top-connected
- `serverInfo.version` now reads from `mix.exs`

### v0.3.0
- `file_path` no longer null in `find_all_callers` results
- `critical_files` betweenness centrality working for all graph sizes
- Dead code convention filter for JS/TS (GET, POST, generateStaticParams, etc.)

### v0.2.0
- CI/CD, Makefile, Docker Hub publishing
- Streamable HTTP transport (replaces SSE)
- Ollama embeddings (replaces Bumblebee/EXLA)
- Go language support, dead code detection, import graph tracking

## License

MIT
