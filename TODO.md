# TODO — Next Release (v0.3.0)

Tracking bugs, improvements, and OSS prep items from council-hub feedback.

---

## 🔴 Critical

- [x] **`find_dead_code` false positives on framework codebases**
  Framework-convention exports (Next.js `GET`/`POST` route handlers, page components, SvelteKit routes) always appear dead because the call graph has no visibility into framework-level invocation. Needs framework-aware filtering or a warning message in the tool response.

- [x] **`find_all_callers` returns `file_path: null`**
  Callers are resolved from the graph cache which doesn't always preserve file paths. Should resolve paths from `ChunkCache` as a fallback. Affects `analyze_impact` depth too.

---

## 🟡 Medium

- [x] **`get_graph_stats` `critical_files` always `[]`**
  High-betweenness threshold is too aggressive for smaller projects. Tune threshold to scale with project size or always return top-N regardless of threshold.

- [ ] **Framework internals dominate top-connected nodes**
  On shadcn/ui projects, `Comp` (degree 546) and `cn()` (473) flood the graph and bury real app modules. Consider filtering known utility patterns or providing a separate "app-code" ranking that excludes `node_modules`-originated names.

- [ ] **Default `reindex` with no path indexes Nexus itself**
  First-time users get Elixir results with no relation to their project and no warning. Should warn or error if no path is given and no previously-indexed project is detected.

- [ ] **`serverInfo.version` hardcoded to `"1.0.0"`**
  Should call `ElixirNexus.version()` in `MCPServer` to return the actual app version from `mix.exs`.

- [ ] **Docker image still ~3.3GB**
  Bumblebee/EXLA removed but image remains large. Investigate multi-stage build with a slim runtime image.

- [ ] **Deprecated `version` key in `docker-compose.yml`**
  Remove `version: '3.8'` — Docker warns on every command.

---

## 🟢 Nice-to-have

- [ ] **Path alias resolution (`@/`) in `find_module_hierarchy`**
  Imports using `@/components/ui/*`, `next/link`, etc. aren't resolved to file paths. Auto-detect `tsconfig.json` `paths` to map aliases to real file paths.

- [ ] **Configurable Ollama model via env var**
  `nomic-embed-text` is hardcoded. Expose `OLLAMA_MODEL` env var so users can swap embedding models.

- [ ] **MCP tool timeout — upstream or proper config**
  Dockerfile patches ExMCP's `message_processor.ex` via `sed` to raise timeout to 120s. Should configure via ExMCP options or upstream the change.

- [ ] **Tool/server naming for non-Elixir discoverability**
  Server named `elixir-nexus` discourages JS/TS/Go/Python users. Consider surfacing as `code-nexus` in MCP tool listings while keeping the repo name.

- [ ] Improve test coverage around project switching (switching collections, ETS reload, file watcher re-wiring)
  Edge cases: switching while indexing is in progress, switching to a deleted collection, rapid successive switches.

---

## 📦 OSS Prep (remaining)

- [ ] **Secret audit** — run `gitleaks` or `trufflehog` on git history
- [ ] **`.env.example`** — document `QDRANT_URL`, `OLLAMA_URL`, `MCP_HTTP_PORT`, `WORKSPACE`, `WORKSPACE_HOST`, `OLLAMA_MODEL`
- [ ] **README.md at repo root** — GitHub-facing README (current `docs/DOCKERHUB.md` is close, needs adapting)
- [ ] **GitHub topics** — add discoverability tags (`mcp`, `code-intelligence`, `elixir`, `tree-sitter`, `qdrant`, `semantic-search`)

---

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
