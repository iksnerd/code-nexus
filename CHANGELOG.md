# Changelog

## v1.4.2
- **Dockerfile: build in `MIX_ENV=prod`** — compiled artefacts now land in `_build/prod/` matching the runtime env; adds `mix phx.digest` to generate the static asset cache manifest required by Phoenix in prod mode

## v1.4.1
- **Block internal codebase indexing** — `reindex` and `POST /api/index` now reject non-workspace paths in Docker mode; no accidental indexing of `/app`
- **Filter `_test` collections from UI dropdown** — test-run artifacts no longer clutter the project switcher
- **Go dead-code false positives fixed** — `Test*`, `Benchmark*`, `Fuzz*`, `Example*` functions filtered (same pattern as JS/TS framework filter); eliminates ~38/49 false positives on real Go projects
- **Skill bundling tests** — 3 assertions guard against the v1.3.x class of `.agents/` packaging failures
- **`make docker.publish.fresh`** — `--no-cache` rebuild variant for structural Dockerfile changes

## v1.4.0
- **Prometheus metrics** — `GET /metrics` endpoint (Prometheus text format 0.0.4) via `telemetry_metrics_prometheus_core`. Exposes search latency/count, indexing pipeline throughput, Qdrant upsert and hybrid search latency, embed-and-store batch stats, and BEAM VM metrics (memory, run queue, process count). Scrape with any Prometheus-compatible collector.

## v1.3.5
- **OSS prep** — untrack Rust build artifacts (`native/tree_sitter_nif/target/`), set `MIX_ENV: prod` in docker-compose, fix broken `.claude/skills` symlink (relative path survives clone on any machine)
- **Docs** — README prerequisites, fix indexing section, port, test count; DOCKERHUB.md tags current; remove stale `quickstart.sh` and orphaned `.mmd` files
- **CI fix** — test collection race condition: `QdrantClient.init/1` now creates the default collection synchronously in test env using `Mix.env() == :test` (prior `Application.get_env` check was always `nil` because `config/test.exs` is not imported by `config/config.exs`)

## v1.3.4
- **Fix: skills wiped at runtime by dev-mode code reload** — v1.3.3 baked skills correctly into the builder's `.beam` files, but the runtime stage didn't include `.agents/`. Phoenix's `code_reloader: true` (dev mode in docker-compose.yml) recompiled `MCPServer.Resources` at boot, found `@skills_dir` empty, and overwrote the well-formed `.beam` with an empty `@skill_content`. Fix: also copy `.agents/` into the runtime stage so dev-mode recompile sees the source. Production-mode (no code reloader) wouldn't have this problem, but matching the running config is safer than counting on it.

## v1.3.3
- **Fix: `.dockerignore` was hiding SKILL.md from the build context** — v1.3.2 added `COPY .agents .agents` to the Dockerfile but `.dockerignore` had `*.md` (with only `!mix.exs` exception), so Docker never put any markdown into the build context. Compile-time skill enumeration ran on a directory without SKILL.md files. Add `!.agents/**/*.md` exception so bundled skills actually get embedded.

## v1.3.2
- **Fix: Docker image missing bundled skills** — `.agents/` was not copied into the builder stage, so the v1.3.0/v1.3.1 published images compiled `Resources.skill_index/0` with an empty directory and shipped zero skills. Added `COPY .agents .agents` before `mix compile`. The skill content is baked into the module binary at compile time, so the runtime stage is unchanged.

## v1.3.1
- **Restrict MCP-exposed skills to user-facing client guides** — only `nexus-client-*` skills are exposed as `nexus://skill/<name>` resources. Internal-development skills (Elixir/OTP/Phoenix patterns, code-nexus internals) stay in `.agents/skills/` for repo contributors but aren't surfaced over the wire. Three new client skills shipped:
  - `nexus-client-search-recipes` — query patterns for `search_code`, when grep wins, intent-based phrasing
  - `nexus-client-refactoring-workflow` — `analyze_impact` → `find_all_callers` recipe and `depth` parameter guide
  - `nexus-client-onboarding` — first-look workflow for unfamiliar codebases, the right tool order

## v1.3.0
- **Skills exposed as MCP resources** — every bundled skill in `.agents/skills/` is now reachable as `nexus://skill/<name>`, with a `nexus://skills/index` listing all of them. Resources are enumerated and embedded at compile time (`@external_resource` triggers a recompile when any `SKILL.md` changes), so the running container needs no filesystem access to serve them.
- **`load_resources` tool fallback for clients without resource support** — the existing tool now also lists skills in its no-arg response, so MCP clients that only speak tools (not resources) can still discover and read skills via `load_resources(uri: "nexus://skill/<name>")`.

## v1.2.9
- **Image catch-up release** — rolls up v1.2.8 (test env short-circuit, slim CI triggers), the `vectors_controller` scroll 404 handler, and the `mcp_server_query_tools` flake fix (defensive `Map.get` for optional chunk fields, `on_exit` cache cleanup). No runtime behavior change for non-test code paths; just brings the published image version stamp in sync with main.

## v1.2.8
- **Skip real Ollama calls in tests** — `EmbeddingModel.embed_batch/1` short-circuits to `{:error, :test_mode}` when `config :elixir_nexus, env: :test`. Tests that called `Indexer.index_file/1` were previously timing out on `econnrefused` to localhost:11434 in CI (no Ollama service). Existing TF-IDF fallback path handles the error gracefully. CI test runtime drops from ~10min back to ~30s.
- **Slim CI triggers** — `.github/workflows/ci.yml` no longer runs on tag pushes (releases are local via Makefile). PR + main push still run tests; secret scan stays scheduled weekly.

## v1.2.7
- **Add Go convention dirs to source detection** — `cmd/`, `internal/`, `pkg/` are now in `@indexable_dirs`. Without this, monorepos like council-hub had `mcp-server/cmd/` skipped during depth-2 detection, even though the Go files inside it should be indexed. `find_project_root/1` source-dir list also gets the additions so paths like `/workspace4/mcp-server/cmd` correctly strip to the parent module.

## v1.2.6
- **Disambiguate sub-project collection names** — when a project is reindexed from a subdirectory of a single-project workspace mount (e.g. `/workspace4/mcp-server` under `WORKSPACE_HOST_4=/Users/yourname/council-hub`), the collection name now prefixes the parent mount's host basename: `nexus_council_hub__mcp_server` instead of the ambiguous `nexus_mcp_server`. Multi-project mounts (`WORKSPACE_HOST=/Users/yourname/projects`) and root-mount reindexes are unaffected.

## v1.2.5
- **Monorepo source-dir detection** — `IndexingHelpers.detect_indexable_dirs/1` now descends one level when no top-level source dir is found. Repos like `council-hub` (with `channel-plugin/src`, `mcp-server/cmd`, `ui/lib` at depth 2) now index all subprojects in a single `reindex(...)` call instead of just the root files. Single-project repos still take the fast top-level path.

## v1.2.4
- **No auto-create of default collection at boot** — `QdrantClient.init/1` no longer schedules `:ensure_collection`. Previously this produced a duplicate `nexus_app` collection alongside the explicitly-indexed `nexus_<project>` for the same code (the in-container `/app` is the same source as host-mounted `~/www/elixir-nexus`). The default collection is now created on first explicit `reindex(...)`. Searches against a non-existent collection still fall back to the indexer keyword search (existing 404 handling), so this is a quieter-state change, not a breaking one.

## v1.2.3
- **Fix collection name for single-project mounts** — when `WORKSPACE_HOST_N` points at the project root itself (v1.2.2), the resolved container path is `/workspaceN`, which previously produced a useless `nexus_workspaceN` collection name. `IndexManagement.ensure_collection_for_project/2` now accepts the user's `display_path` and prefers the bare project name (e.g. `nexus_council_hub` instead of `nexus_workspace4`).
- **Trim trailing underscores in collection names** — prevents `nexus_` / `nexus__` artifacts when the source path ends in `.` or `_`.

## v1.2.2
- **Single-project workspace mounts** — when `WORKSPACE_HOST_N` points at the project root itself (rather than a parent directory of projects), `reindex(<project-name>)` now resolves bare names to the mount itself. Useful for repos like `~/council-hub` that aren't grouped under a parent. The `available projects` list also includes these mounts (detected via top-level source dirs or project markers like `README.md`, `Dockerfile`, `mix.exs`, `package.json`, etc.).

## v1.2.1
- **Workspace mounts extended to 5 slots** — `WORKSPACE_4`/`WORKSPACE_5` (with matching `WORKSPACE_HOST_4`/`WORKSPACE_HOST_5`) now mount additional host directories at `/workspace4`/`/workspace5`. Useful when projects are scattered across `~/GolandProjects`, `~/WebstormProjects`, `~/PyCharmProjects`, etc.
- **Better busy reindex error message** — instead of `Reindex failed: :indexing_in_progress`, the response now names the project currently being reindexed and explains why concurrent reindex of different projects is rejected.
- **Quieter boot logs** — the expected 409 "Collection already exists" response on startup is now logged at debug, not warning.

## v1.2.0
- **Default embedding model is now `embeddinggemma:300m`** — `embedding_model.ex` `@default_model`, `docker-compose.yml`, `.env.example`, `config/config.exs` all updated. `OLLAMA_MODEL=nomic-embed-text` continues to work as an override.
- **Fix concurrency race in collection switch** — `reindex` now pre-checks `Indexer.busy?/0` before calling `ensure_collection_for_project`, so a rejected reindex no longer swaps the active Qdrant collection out from under in-flight Broadway batches (which previously caused hundreds of `404 Not found: Collection 'nexus_X' doesn't exist` errors).
- **Fix cold-start Ollama timeouts dropping chunks** — `embed_batch/1` now retries on `:timeout`/`:connect_timeout`/`:econnrefused` (up to 3 attempts, linear backoff); `recv_timeout` raised from 30s → 60s; `EmbeddingModel.warm_up/0` runs at supervisor start so the first real batch doesn't block on a cold model load.
- **Fix Docker healthcheck** — `code_nexus` healthcheck now uses `bash /dev/tcp` (the published image has no `curl`), so the container is correctly marked healthy.

## v1.1.0
- **Multi-workspace Docker mounts** — `WORKSPACE_2`/`WORKSPACE_3` env vars mount additional host directories at `/workspace2`/`/workspace3`. Bare project names in `reindex` are resolved across all active mounts, so projects scattered across different host directories are all accessible without a shared parent.

## v1.0.5
- **Fix Qdrant test collection leak** — cleanup in 3 MCP server reindex tests moved to `on_exit` so it runs even on test failure; deleted 19 previously accumulated orphan collections
- **Test splits** — `mcp_server_test.exs`, `relationship_graph_test.exs`, `indexer_test.exs` split into 8 focused files, completing the test reorganisation series
- **`qdrant_client.ex` internal reorganisation** — sections reordered into clear domains: configuration, GenServer lifecycle, collection management, search (read-only), point reads, point writes, callbacks, HTTP helpers
- **QdrantClient tests** — 20 new tests covering `collection_name/0` derivation logic, `active_collection/0` Application env reads, process dict override, and `switch_collection_force/1`; collection management functions now have coverage

## v1.0.4
- **Fix dashboard broken LiveView** — vendor JS files (`phoenix.min.js`, `phoenix_live_view.min.js`) were not tracked in git, so Docker builds excluded them. All LiveView interactivity (buttons, graph, search) was broken in Docker mode.
- **Static asset tests** — new `static_assets_test.exs` verifies vendor JS and image files are served with 200
- **Graph page tests** — new `graph_live_test.exs` covers mount, refresh, collection switch, and event handling
- **Test collection cleanup** — `ExUnit.after_suite` now deletes the test Qdrant collection after each test run

## v1.0.3
- Rename container name `elixir_nexus` → `code_nexus` in docker-compose and Makefile

## v1.0.2
- **Fix `load_resources` entity types showing as `"unknown"`** — `nexus://project/overview`, `nexus://project/architecture`, and `nexus://project/hotspots` now correctly read `node["entity_type"] || node["type"]`, matching the key used by `RelationshipGraph.build_graph/1`
- **13 new tests for `MCPServer.Resources`** — overview, architecture, hotspots, and not-indexed message paths now directly covered

## v1.0.1
- **Internal refactor** — split 4 large source files (`search/queries.ex`, `mcp_server.ex`, `javascript_extractor.ex`, `go_extractor.ex`) into focused domain sub-modules; all public APIs unchanged
- **Test reorganisation** — 5 large test files split into 23 focused test files, matching source module boundaries
- **Direct unit tests for `EntityResolution` and `PathResolution`** — `matches_entity_name?/2`, `import_matches_file?/2`, `find_entity_multi_strategy/2`, and `PathResolution` pure functions now have dedicated test coverage

## v1.0.0
- **Server renamed to `code-nexus`** — MCP server name updated for discoverability by JS/TS/Go/Python users
- **`"use client"` / `"use server"` directive indexing** — Next.js directives tagged as `directive:use-client` / `directive:use-server` metadata on file-level entities; improves search precision on full-stack codebases
- **tsconfig path alias resolution** — `find_module_hierarchy` now reads `tsconfig.json` `compilerOptions.paths` to resolve `@/*` → `src/*` style aliases accurately
- **`OLLAMA_MODEL` env var** — embedding model is now configurable via `OLLAMA_MODEL` (default: `nomic-embed-text`)
- **Reindex default-path warning** — when no `path` is given in local/no-workspace mode and no project has been indexed yet, result includes a `warning` key
- **Extended graph noise filter** — `get_graph_stats` top-connected now filters short PascalCase wrapper names (`Comp`, `Box`, `Row`, etc.) and common React utility names (`createContext`, `memo`, `Fragment`, etc.)

## v0.9.0
- **MCP Resources** — expose codebase knowledge as MCP resources (`nexus://guide/tools`, `nexus://project/overview`, `nexus://project/architecture`, `nexus://project/hotspots`) for resource-aware clients
- **`load_resources` fallback tool** — list or read resources from clients that only support tools (follows MCP creator's recommended pattern)
- Dynamic resources generated from ETS caches (ChunkCache, GraphCache) — no Qdrant calls needed

## v0.8.0
- **Concurrent QdrantClient reads** — cross-project isolation, process dictionary collection pinning
- **Caller refinement** — callers now resolve to enclosing function, not module
- **Fuzzy callees** — short name matching for `find_all_callees`
- **`@/` path alias resolution** — JS/TS `@/components/...` imports resolved to actual entities
- **Reindex warning** — omitting `path` when workspace projects exist now returns an error instead of silently indexing `/app`

## v0.7.1
- **Qdrant test collection cleanup** — deleted 84 orphaned test collections, added `QdrantClient.delete_collection/1` by name, fixed test cleanup to prevent future accumulation

## v0.7.0
- **Broadway error handling** — parse failures now properly use `Broadway.Message.failed/2` instead of silently swallowing errors
- **TFIDFEmbedder ETS crash-safe** — IDF table moved to CacheOwner (survives TFIDFEmbedder crashes)
- **Deduplicated indexing handlers** — extracted `prepare_reindex/1` and `do_index_files/3`
- **`is_dirty?/1` → `dirty?/1`** — renamed to follow Elixir naming convention
- **Single source of truth for extensions** — `DirtyTracker` now delegates to `IndexingHelpers.all_indexable_extensions/0`
- **`search_chunks/2` optimization** — removed GenServer bottleneck, calls ETS directly
- **ChunkCache.search performance** — replaced O(n) `length/1` with O(1) counter accumulator in foldl
- **15 Agent Skills** — `.agents/skills/` with 10 general Elixir/OTP/Phoenix skills + 5 project-specific skills

## v0.6.0
- **CI fixed** — NIF and file watcher tests now correctly excluded in CI; version assertion no longer hardcoded
- **`find_all_callers` line numbers** — `start_line`/`end_line` now populated with real function positions (was always 0)
- **`get_graph_stats` includes `project_path`** — survives MCP server restarts so callers can detect stale index
- **Docker image 588MB** (was 3.28GB) — multi-stage build drops Rust toolchain from runtime; added `.dockerignore`

## v0.5.0
- D3 force-directed graph at `/graph` — 3 edge types, hover highlighting, glow rings, 500-node cap

## v0.4.0
- JSX component renders tracked as call edges in `find_all_callees`
- `find_dead_code` filters framework conventions (Next.js pages, layouts, route handlers, loading)
- Framework utility noise (`cn`, `Comp`, `Slot`) filtered from `get_graph_stats` top-connected
- `serverInfo.version` now reads from `mix.exs`

## v0.3.0
- `file_path` no longer null in `find_all_callers` results
- `critical_files` betweenness centrality working for all graph sizes
- Dead code convention filter for JS/TS (GET, POST, generateStaticParams, etc.)

## v0.2.0
- CI/CD, Makefile, Docker Hub publishing
- Streamable HTTP transport (replaces SSE)
- Ollama embeddings (replaces Bumblebee/EXLA)
- Go language support, dead code detection, import graph tracking
