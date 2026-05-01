# CodeNexus

Code intelligence MCP server — provides graph-powered semantic search, call graph traversal, and impact analysis for any codebase.

## Before Pushing

Always run these checks before pushing to avoid CI failures:

```bash
mix compile --warnings-as-errors   # Must compile with zero warnings
mix format --check-formatted       # Must pass formatter check
mix test --exclude performance --exclude multi_project  # Must pass tests
```

If formatting fails, run `mix format` to auto-fix, then re-commit.

## Building

```bash
mix deps.get
mix compile
```

### Static JS vendor files

`priv/static/js/phoenix.min.js` and `priv/static/js/phoenix_live_view.min.js` are vendor files required by the Phoenix LiveView dashboard. They are force-tracked in git (`git add -f`) despite `/priv/static/` being in `.gitignore`. Without them, LiveView fails to connect and all UI interactivity (buttons, graph, search) breaks.

If these files are missing (e.g. after a fresh clone or dep upgrade), copy them from deps:
```bash
cp deps/phoenix/priv/static/phoenix.min.js priv/static/js/
cp deps/phoenix_live_view/priv/static/phoenix_live_view.min.js priv/static/js/
git add -f priv/static/js/phoenix.min.js priv/static/js/phoenix_live_view.min.js
```

### Tree-sitter NIF (Rust)

The tree-sitter parser is a Rust NIF that must be compiled separately. Requires Rust toolchain (`rustup`).

**To compile the NIF through Mix (correct ERTS ABI):**
```bash
# Temporarily set skip_compilation? to false in lib/elixir_nexus/tree_sitter_parser.ex
# Then:
PATH="$HOME/.cargo/bin:$PATH" mix compile --force
# Revert skip_compilation? to true after
```

The NIF binary lives at `priv/native/tree_sitter_nif.so`. It's loaded at runtime via `load_from` — no recompilation needed for Elixir changes, only for Rust source changes.

**Important:** The Cargo crate (`native/tree_sitter_nif/Cargo.toml`) uses `rustler = "0.37"` which must match the Elixir dep (`{:rustler, "~> 0.37"}`). The NIF must be compiled through Mix (not raw `cargo build`) to get the correct ERTS NIF ABI linking.

**Docker NIF build:** The Dockerfile automatically handles NIF compilation for Linux — it deletes the host macOS `.so`, temporarily enables `skip_compilation?: false`, runs `mix compile --force`, then restores the flag. No manual steps needed.

**After changing Rust source (local):**
1. Edit `lib/elixir_nexus/tree_sitter_parser.ex` — remove `skip_compilation?: true` and `load_from`
2. Run `PATH="$HOME/.cargo/bin:$PATH" mix compile --force`
3. Restore `skip_compilation?: true, load_from: {:elixir_nexus, "priv/native/tree_sitter_nif"}`
4. Restart the server
5. Rebuild Docker image if using Docker: `docker-compose build elixir_nexus`

## Testing

```bash
mix test                    # All tests (~725, 0 compile warnings)
mix test --trace            # Verbose output
mix test --include performance  # Performance benchmarks (32 tests)
mix test test/elixir_nexus/parsers/  # Parser tests
mix test test/elixir_nexus/indexer_file_test.exs      # Single-file indexing tests
mix test test/elixir_nexus/indexer_directory_test.exs # Directory indexing tests
```

Tests run with `skip_compilation?: true` so they don't need Rust/Cargo in PATH.

## Running

**Prerequisites:** Ollama running on host with `embeddinggemma:300m` pulled (`ollama pull embeddinggemma:300m`). Override with `OLLAMA_MODEL=nomic-embed-text` if you prefer the older default.

```bash
# Docker — starts Phoenix :4100 + MCP Streamable HTTP :3002 in a single BEAM
WORKSPACE=~/www docker-compose up -d
```

When `MCP_HTTP_PORT` env var is set (docker-compose sets it to `3002`), `application.ex` auto-starts the MCP HTTP server alongside Phoenix in a single BEAM instance. Both share ETS caches and PubSub — no sync delay. Requires Qdrant at `http://localhost:6333` (configurable via `QDRANT_URL`) and Ollama at `http://host.docker.internal:11434` (configurable via `OLLAMA_URL`).

**Note:** Docker does not mount the host source (no `.:/app` volume) — the image is self-contained with its own Linux-compiled NIF and BEAM files. After code changes, rebuild with `docker-compose build elixir_nexus`.

### Workspace mount (Docker)

Set `WORKSPACE` to mount an external directory at `/workspace:ro` inside the container. Up to four additional mounts are supported via `WORKSPACE_2`…`WORKSPACE_5` (each needs a matching `WORKSPACE_HOST_N` for path translation): `WORKSPACE=~/www WORKSPACE_HOST=~/www WORKSPACE_2=~/GolandProjects WORKSPACE_HOST_2=~/GolandProjects WORKSPACE_3=~/WebstormProjects WORKSPACE_HOST_3=~/WebstormProjects docker-compose up -d`. Without `WORKSPACE`, only `/app` (the CodeNexus repo) is indexable. `WORKSPACE_HOST` env var tells the container what host path maps to `/workspace`, enabling automatic path translation in `resolve_path/2` in `mcp_server/path_resolution.ex`.

**Path resolution order** (`reindex` path argument):
1. `nil` / omitted → indexes `/app` (CodeNexus itself)
2. Bare project name (e.g. `"claude-vision"`) → `/workspace/claude-vision` if it exists
3. Full host path (e.g. `"/Users/admin/Documents/claude-vision"`) → stripped via matching `WORKSPACE_HOST_N` → `/workspaceN/claude-vision`
4. Container path (e.g. `"/workspace/claude-vision"`) → passthrough

On failure (path not found or no source dirs), the error message lists available projects in `/workspace`.

### Local development

For building/testing CodeNexus itself:

```bash
ollama pull embeddinggemma:300m                       # Ensure embedding model
docker-compose up -d qdrant                           # Qdrant only
nohup mix phx.server > /tmp/nexus_server.log 2>&1 &  # Phoenix dashboard
mix mcp                                               # MCP stdio transport
mix mcp_http --port 3002                              # MCP Streamable HTTP transport
```

In local mode, MCP and Phoenix are separate BEAM instances sharing Qdrant but not ETS or PubSub.

## Architecture

- **MCP Server** (`lib/elixir_nexus/mcp_server.ex`) — stdio + HTTP (Streamable HTTP at `/mcp`) transport, ex_mcp 0.9.0
- **Phoenix Dashboard** (`lib/elixir_nexus_web/`) — LiveView dashboard on port 4100, auto-syncs from Qdrant
- **Indexing Pipeline** — Broadway-based: parse (tree-sitter/sourceror) -> chunk -> embed (Ollama embeddinggemma:300m, 768-dim) -> store (Qdrant + ETS)
- **ETS Caches** — `ChunkCache` (chunks by file) + `GraphCache` (call graph nodes) — owned by `CacheOwner` GenServer
- **TF-IDF ETS** — IDF vocabulary in ETS with `read_concurrency: true` for lock-free concurrent embeddings
- **Supervision** — `rest_for_one` strategy: if a dependency crashes, all processes started after it restart
- **Registry** — `ElixirNexus.Registry` for IndexingProducer PID lookup

### Multi-instance sync (MCP + Phoenix)

- **Docker mode**: MCP HTTP and Phoenix run in a single BEAM instance — they share ETS, PubSub, and Qdrant. No sync delay.
- **Local mode**: MCP (stdio) and Phoenix are separate BEAM instances — they share Qdrant but not ETS or PubSub
- Dashboard auto-detects when Qdrant point count diverges from local ETS (every 3s tick) and reloads via `ProjectSwitcher.reload_from_qdrant/0`
- Within a single BEAM instance, PubSub delivers live updates for indexing progress, completion, and file changes

### Multi-project support

- Each project gets its own Qdrant collection (`nexus_<project_name>`)
- MCP `reindex(path: "/path/to/project")` auto-detects source dirs, switches collection, indexes, and re-wires file watchers
- Dashboard dropdown lists all Qdrant collections; switching reloads ETS from Qdrant via `ProjectSwitcher`

### MCP spec compliance (ex_mcp 0.9.0)

- **`get_tools/0` override**: ExMCP DSL stores atom keys (`:input_schema`, `:display_name`, `:meta`), but MCP spec requires camelCase strings (`inputSchema`). `mcp_server.ex` overrides `get_tools/0` to normalize keys so clients discover tools correctly.
- **Dockerfile timeout patch**: ExMCP's default tool call timeout is 10s, too short for `reindex`. The Dockerfile patches `message_processor.ex` via `sed` to increase it to 120s, then recompiles `ex_mcp`.
- **MCP string arg coercion**: MCP tool arguments arrive as JSON strings even for numeric params. The `to_int/2` helper in `mcp_server/response_format.ex` coerces string args to integers with a default fallback. Must be used for all numeric `deftool` params.

### Auto-reindex on queries

MCP query tools (`search_code`, `find_all_callees`, `find_all_callers`, `analyze_impact`, `get_community_context`, `get_graph_stats`, `find_module_hierarchy`, `find_dead_code`) automatically check for dirty files via `DirtyTracker.get_dirty_files_recursive/1` before executing. Changed files are reindexed individually via `Indexer.index_file/1` (fast, single-file) so queries always return fresh results. Deleted files are also cleaned up from all caches during this pass. Only active after an initial `reindex` (state must have `:indexed_dirs`).

### File deletion handling

When the FileWatcher detects a `:removed`/`:deleted` event and confirms the file is gone from disk, it calls `Indexer.delete_file/1` which orchestrates cleanup across ChunkCache, GraphCache, Qdrant, and DirtyTracker. The `maybe_reindex_dirty/1` pass before queries also scans for files in ChunkCache that no longer exist on disk.

### Concurrency & safety

- Concurrent `index_directory` / `index_directories` calls are rejected with `{:error, :indexing_in_progress}` to prevent state corruption
- Graph rebuild after indexing is async (non-blocking)
- All Qdrant HTTP calls have 30s timeouts (120s for batch upsert)
- MCP tool results use safe `Jason.encode` (not `encode!`) — serialization failures return error text instead of crashing

### Tree-sitter NIF depth limits

The NIF filters AST nodes via `is_significant_node()` and has depth limits (20/25). When adding support for new languages or node types, update `is_significant_node` in `native/tree_sitter_nif/src/lib.rs` and rebuild.

Key node types that must be included:
- Declarations: `function`, `method`, `class`, `interface`, `declaration`, `definition`
- Calls: `call_expression`, `new_expression`, `member_expression`
- Blocks: `statement_block`, `expression_statement`, `return_statement`, control flow
- Imports: `import_clause`, `named_imports`, `import_specifier`, `string`, `string_fragment`
- Python: `import_statement`, `import_from_statement`, `dotted_name`, `decorator`, `decorated_definition`
- Go: `selector_expression`, `field_identifier`, `type_identifier`, `pointer_type`, `parameter_declaration`, `package_clause`, `package_identifier`, `interpreted_string_literal`, `import_spec`, `import_spec_list`, `type_spec`, `field_declaration`, `method_spec`, `short_var_declaration`, `composite_literal`
- Generic: `import_declaration`, `use_declaration`, `include_directive`, `package_clause`

### Source directory detection

`IndexingHelpers.detect_indexable_dirs/1` checks for: lib, src, app, pages, components, utils, packages, services, infrastructure, repositories, core, hooks, api, modules, controllers, models, views.

### Telemetry events

| Event | Metadata | When |
|-------|----------|------|
| `[:nexus, :pipeline, :file_parsed]` | duration_ms, chunk_count, file | File successfully parsed |
| `[:nexus, :pipeline, :file_error]` | file, reason | File parse failure |
| `[:nexus, :search, :query]` | duration_ms, result_count, query | Search query completed |
| `[:nexus, :qdrant, :upsert]` | duration_ms, point_count | Batch upsert to Qdrant |
| `[:nexus, :qdrant, :upsert_error]` | batch_size, reason | Batch upsert failed |
| `[:nexus, :qdrant, :hybrid_search]` | duration_ms, limit | Hybrid search completed |
| `[:nexus, :embed_and_store]` | duration_ms, chunk_count | Embedding + storage batch |

## Key files

| File | Purpose |
|------|---------|
| `native/tree_sitter_nif/src/lib.rs` | Rust NIF — tree-sitter parsing + AST filtering |
| `lib/elixir_nexus/parsers/javascript_extractor.ex` | JS/TS facade — delegates to `parsers/javascript/{entities,calls,imports_exports}.ex` |
| `lib/elixir_nexus/parsers/python_extractor.ex` | Python entity + call + import + decorator extraction |
| `lib/elixir_nexus/parsers/go_extractor.ex` | Go facade — delegates to `parsers/go/{entities,calls,imports_package}.ex` |
| `lib/elixir_nexus/parsers/generic_extractor.ex` | Fallback extractor with import support for Rust/Java |
| `lib/elixir_nexus/search/queries.ex` | Thin facade delegating to domain sub-modules (entity_resolution, caller_finder, callee_finder, impact_analysis, community_context, dead_code_detection, graph_stats, module_hierarchy) |
| `lib/elixir_nexus/search/entity_resolution.ex` | Entity name matching — highest-centrality file; `matches_entity_name?/2`, `find_entity_multi_strategy/2` |
| `lib/elixir_nexus/search/graph_boost.ex` | Relationship-aware search result re-ranking |
| `lib/elixir_nexus/relationship_graph.ex` | Graph building with name-indexed O(1) resolution |
| `lib/elixir_nexus/indexing_helpers.ex` | File processing, embedding, Qdrant storage |
| `lib/elixir_nexus/mcp_server.ex` | MCP tool DSL + `handle_tool_call/3` dispatch — delegates to sub-modules |
| `lib/elixir_nexus/mcp_server/index_management.ex` | Collection switching, dirty-file auto-reindex, deleted file cleanup |
| `lib/elixir_nexus/mcp_server/path_resolution.ex` | Workspace path translation (`resolve_path/2`, `workspace_hint/0`) |
| `lib/elixir_nexus/mcp_server/response_format.ex` | JSON reply helpers, `to_int/2` numeric coercion, result compaction |
| `lib/elixir_nexus/mcp_server/resources.ex` | MCP resource generators (overview, architecture, hotspots) |
| `lib/mix/tasks/mcp_http.ex` | Mix task for HTTP/SSE MCP transport |
| `lib/elixir_nexus/project_switcher.ex` | Collection switching + ETS reload from Qdrant |
| `lib/elixir_nexus/embedding_model.ex` | Ollama embedding client (768-dim, default `embeddinggemma:300m`); retries on timeout/cold-start; `warm_up/0` called from Application |
| `lib/elixir_nexus/tfidf_embedder.ex` | TF-IDF embedder with ETS-backed IDF for concurrent reads (fallback + sparse) |
| `lib/elixir_nexus/dirty_tracker.ex` | SHA256-based incremental indexing (polyglot) |
| `lib/elixir_nexus/qdrant_client.ex` | Qdrant GenServer — collection management, hybrid search, point ops; read-only calls bypass mailbox |
