# TODO — Next Release (v1.1.0)

Tracking bugs, improvements, and OSS prep items from council-hub feedback.

---

## 🟡 Medium

- [ ] **`analyze_impact` / `find_all_callers` resolve to module, not enclosing function**
  While start_line/end_line are now correctly propagated from the graph cache (fixed in v0.6.0), callers still resolve to the module-level entity rather than the tightest enclosing function. e.g. `find_all_callers("FileExplorer")` returns `page` module instead of `TorrentDetailsPage`. Root cause: the call edge is on the module chunk, not the function chunk. Needs chunking-level fix to attribute calls to their enclosing function.

---

## 🟢 Nice-to-have

- [ ] **`find_module_hierarchy` — populate `children` for function entities**
  `children` is always `[]` for function-level entities. Populate with JSX components rendered (once JSX edges are tracked) or nested function declarations. Currently only useful for module-level hierarchy.

- [ ] **`search_code` — boost `"use server"` / no-directive chunks for data-fetching queries**
  Directive metadata is now indexed (v1.0.0). Next step: in search, detect data-fetching intent and boost chunks tagged `directive:use-server` or untagged (default server in App Router).

- [ ] **Secret audit** — run `gitleaks` or `trufflehog` on git history (neither installed locally; add to CI)

---

## ✅ Done (v1.0.0)

- [x] **MCP server named `code-nexus`** — `server_info` name changed from `elixir-nexus` for non-Elixir discoverability
- [x] **GitHub topics added** — `mcp`, `code-intelligence`, `elixir`, `tree-sitter`, `qdrant`, `semantic-search` on iksnerd/code-nexus
- [x] **Framework noise filter extended** — `get_graph_stats` top-connected now also rejects short PascalCase wrapper names (`Comp`, `Box`, `Row`, etc.) via `~r/^[A-Z][a-z]{0,3}$/` + known React utility names (`createContext`, `memo`, etc.)
- [x] **`reindex` no-path warning** — when no `path` given and no prior index in state, result includes a `warning` key explaining the default (CodeNexus itself)
- [x] **`"use client"` / `"use server"` directive indexed as metadata** — `javascript_extractor.ex` detects directive from first 5 lines, tags file-level entity `is_a: ["directive:use-client"]` / `["directive:use-server"]`, and sets `content` to the directive string for embedding
- [x] **Path alias resolution via tsconfig.json** — `resolve_by_path_alias/2` now reads `compilerOptions.paths` from `tsconfig.json` in the project root; resolves `@/*` → `src/*` style mappings before falling back to generic `@/` stripping
- [x] **`OLLAMA_MODEL` env var wired** — `embedding_model.ex` reads `System.get_env("OLLAMA_MODEL")` with `"nomic-embed-text"` default (was hardcoded)
- [x] **MCP timeout patch documented** — Dockerfile `sed` patch improved with regex for both `10000`/`10_000` forms; TODO comment links to upstream issue
- [x] **Project switching edge case tests** — 3 new tests: nonexistent collection returns error without corrupting caches; rapid successive switches leave caches valid; switch while indexer is idle completes without blocking
- [x] **Dead code investigation** — `table_name`, `get_tools`, `version` are all legitimately used (false positives from `find_dead_code` tool on overrides/attribute-backed functions)

---

## ✅ Done (v0.7.1 — Qdrant test collection cleanup)

- [x] **Deleted 84 orphaned test collections from Qdrant** — accumulated from `mcp_server_test.exs` runs that never cleaned up
- [x] **Added `QdrantClient.delete_collection/1`** — delete collection by name (existing `/0` only deletes active)
- [x] **Fixed test cleanup** — 3 MCP server tests now delete their Qdrant collections alongside temp dir cleanup

## ✅ Done (v0.7.0 — skills-based review fixes)

- [x] **Broadway parse errors now properly failed** — `indexing_pipeline.ex` uses `Broadway.Message.failed/2` + `handle_failed/2` with Indexer acks
- [x] **TFIDFEmbedder ETS table moved to CacheOwner** — survives crashes, concurrent readers safe
- [x] **Deduplicated `index_directory`/`index_directories`** — extracted `prepare_reindex/1` + `do_index_files/3`
- [x] **Renamed `is_dirty?/1` → `dirty?/1`** — all callers + tests updated
- [x] **Consolidated `@indexable_extensions`** — `DirtyTracker` now delegates to `IndexingHelpers.all_indexable_extensions/0`
- [x] **Removed `search_chunks/2` GenServer bottleneck** — calls ChunkCache ETS directly
- [x] **Fixed O(n) `length/1` in ChunkCache.search** — `{count, results}` tuple accumulator
- [x] **Fixed node structure inconsistency** — `update_file/2` now uses `"entity_type"` (was `"type"`), all 4 consumers updated

## ✅ Done (v0.6.0)

- [x] **CI fixed** — tagged NIF tests with `@tag :nif`, file watcher tests with `@tag :file_watcher`, excluded from CI; fixed stale version assertion
- [x] **`find_all_callers` start_line/end_line no longer hardcoded to 0** — now reads from graph cache node data
- [x] **`GraphCache.update_file` preserves start_line/end_line** — incremental file updates now include line info (was missing, causing null lines after single-file reindex)
- [x] **`get_graph_stats` includes `project_path`** — callers can detect stale/wrong index after MCP restart
- [x] **Docker multi-stage build** — builder stage with Rust toolchain, runtime stage without. Added `.dockerignore`.
- [x] Tests added for start_line preservation in GraphCache and Queries

## ✅ Done (v0.5.0)

- [x] D3 force-directed graph visualization (3 edge types, hover highlighting, glow rings, 500-node cap)
- [x] SVG/simulation bug fixes, name resolution fix
- [x] README overhaul: Bumblebee→Ollama, fresh benchmarks, Ruby support, dashboard screenshots
- [x] Version bumped to 0.5.0, Docker Hub `iksnerd/elixir-nexus:v0.5.0`

## ✅ Done (v0.4.0)

- [x] `find_dead_code` — filename-based convention filter for `page.tsx`, `loading.tsx`, `error.tsx`, `layout.tsx`, `route.ts` etc. (PascalCase default exports no longer flagged as dead)
- [x] `find_all_callees` — JSX component usage tracked as call edges (`<Button />`, `<Card>` etc. now appear in callee results); NIF updated to pass JSX nodes through
- [x] `get_graph_stats` — framework utility noise (`cn`, `clsx`, `Comp`, `Slot`, `twMerge`, etc.) filtered from `top_connected`
- [x] `serverInfo.version` now reads from `mix.exs` via `ElixirNexus.version()` instead of hardcoded `"0.1.0"`
- [x] Removed deprecated `version: '3.8'` key from `docker-compose.yml`
- [x] `.env.example` updated with `OLLAMA_URL` and `OLLAMA_MODEL` env vars
- [x] 18 new tests covering all changes
- [x] Version bumped to 0.4.0

## ✅ Done (v0.3.0)

- [x] `find_dead_code` — framework convention name filter (GET, POST, default, generateStaticParams, etc.) + warning for JS/TS projects
- [x] `find_all_callers` / `critical_files` — `file_path` no longer null after full reindex (`RelationshipGraph.build_graph` now preserves `file_path`, `start_line`, `end_line`)
- [x] 10 new tests covering all three fixes
- [x] Version bumped to 0.3.0, tagged, pushed to GitHub + Docker Hub

## ✅ Done (v0.2.0)

- [x] CI/CD — `.github/workflows/ci.yml` (test + format + Docker Hub publish)
- [x] Makefile — `test`, `format`, `build`, `publish`, `release` targets
- [x] `.formatter.exs` + full codebase formatted
- [x] Version tagged `v0.2.0`, pushed to GitHub
- [x] Docker Hub — `iksnerd/elixir-nexus:latest` + `iksnerd/elixir-nexus:v0.2.0`
- [x] `CONTRIBUTING.md`
- [x] GitHub issue templates (bug_report.yml, feature_request.yml)
- [x] MIT License
- [x] Streamable HTTP transport (SSE → Streamable HTTP)
- [x] Ollama embeddings (Bumblebee/EXLA removed)
- [x] TF-IDF vocabulary rebuilt from Qdrant on startup
- [x] File watcher incremental index updates (deleted files cleaned up)
- [x] `find_module_hierarchy` — file-based module resolution for TS
- [x] Import graph tracking (`get_community_context`, `analyze_impact` follow imports)
- [x] Dead code detection (`find_dead_code`)
- [x] Graph centrality / hot path scoring in `get_graph_stats`
- [x] Go language support — `GoExtractor` with call graph, imports, struct/interface
- [x] Dashboard: local timezone timestamps, delete collections from UI
- [x] Auto-reindex on queries (dirty file detection before every MCP call)
