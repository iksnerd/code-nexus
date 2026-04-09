# TODO — Next Release (v0.5.0)

Tracking bugs, improvements, and OSS prep items from council-hub feedback.

---

## 🔴 Critical

_(none)_

---

## 🟡 Medium

- [ ] **`analyze_impact` / `find_all_callers` resolve to module, not enclosing function**
  Impact tree nodes and caller results show module-level entities (`start_line: 1, end_line: 1`) instead of the specific function that contains the call. e.g. `formatBytes` impact returned `page` module, not `TorrentsPage`. `find_all_callers("FileExplorer")` returned the `page` module instead of `TorrentDetailsPage` at line 60. Both tools share this root cause — need to resolve to the tightest containing function entity, not the module root.

- [ ] **Framework internals dominate top-connected nodes**
  On shadcn/ui projects, `Comp` (degree 546) and `cn()` (473) flood the graph and bury real app modules. Filter or deprioritize single-character names and known utility patterns in `get_graph_stats` top-connected output.

- [ ] **Default `reindex` with no path indexes Nexus itself**
  First-time users get Elixir results with no relation to their project and no warning. Should warn or error if no path is given and no previously-indexed project is detected.

- [ ] **Docker image still ~3.3GB**
  Bumblebee/EXLA removed but image remains large. Investigate multi-stage build with a slim runtime image.

---

## 🟢 Nice-to-have

- [ ] **`search_code` — index `"use client"` / `"use server"` as metadata**
  Data-fetching queries (`revalidate`, `cache`, `fetch`, ISR) currently surface `"use client"` components mid-results. Index the directive as a metadata tag on chunks and boost `"use server"` / no-directive chunks for data-fetching queries. Would meaningfully improve search precision on full-stack Next.js codebases.

- [ ] **`find_module_hierarchy` — populate `children` for function entities**
  `children` is always `[]` for function-level entities. Populate with JSX components rendered (once JSX edges are tracked) or nested function declarations. Currently only useful for module-level hierarchy.

- [ ] **Path alias resolution (`@/`) in `find_module_hierarchy`**
  Imports using `@/components/ui/*`, `next/link`, etc. aren't resolved to file paths. Auto-detect `tsconfig.json` `paths` to map aliases to real file paths.

- [ ] **Configurable Ollama model via env var**
  `nomic-embed-text` is hardcoded. Expose `OLLAMA_MODEL` env var so users can swap embedding models.

- [ ] **MCP tool timeout — upstream or proper config**
  Dockerfile patches ExMCP's `message_processor.ex` via `sed` to raise timeout to 120s. Should configure via ExMCP options or upstream the change.

- [ ] **Tool/server naming for non-Elixir discoverability**
  Server named `elixir-nexus` discourages JS/TS/Go/Python users. Consider surfacing as `code-nexus` in MCP tool listings while keeping the repo name.

- [ ] **Dead code detected in own codebase** — `table_name` in chunk_cache.ex and graph_cache.ex, `get_tools` in mcp_server.ex, `version` in elixir_nexus.ex. Clean up or mark as public API.

- [ ] Improve test coverage around project switching (switching collections, ETS reload, file watcher re-wiring)
  Edge cases: switching while indexing is in progress, switching to a deleted collection, rapid successive switches.

---

## 📦 OSS Prep (remaining)

- [ ] **Secret audit** — run `gitleaks` or `trufflehog` on git history
- [ ] **`.env.example`** — document `QDRANT_URL`, `OLLAMA_URL`, `MCP_HTTP_PORT`, `WORKSPACE`, `WORKSPACE_HOST`, `OLLAMA_MODEL`
- [ ] **README.md at repo root** — GitHub-facing README (current `docs/DOCKERHUB.md` is close, needs adapting)
- [ ] **GitHub topics** — add discoverability tags (`mcp`, `code-intelligence`, `elixir`, `tree-sitter`, `qdrant`, `semantic-search`)

---

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
