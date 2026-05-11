# CodeNexus TODO — v1.10.0 Roadmap

**Current version:** v1.9.0 (EMBEDDING_BACKEND=tfidf switch, arm64-only Docker builds)  
**Status:** Docker running, all quick wins from v1.9.0 already shipped

---

## ✅ Shipped in v1.9.0

- [x] EMBEDDING_BACKEND=tfidf env var for ~10× faster indexing (skip Ollama)
- [x] `make docker.publish.fresh` — Multi-platform `--no-cache` builds
- [x] `MIX_ENV=prod` in Docker (prevents dev reloader from wiping `.agents/`)
- [x] Go test function filtering (exclude `Test*`, `Benchmark*`, `Fuzz*`, `Example*`)
- [x] Skill bundling integration test (`Resources.skill_index()` non-empty assertion)
- [x] arm64-only Docker builds (skip slow amd64 QEMU cross-compile)

---

## 🔴 v1.10.0 — High Priority

### M1: Callers resolve to module, not enclosing function
**Impact:** High — `find_all_callers` and `analyze_impact` return overly coarse results  
**Status:** Open since v0.6.0  
**Details:**
- `find_all_callers("FileExplorer")` returns `page` module at `start_line: 0, end_line: 0` instead of `TorrentDetailsPage` at line 60
- Same issue in `analyze_impact` — impact nodes show module root instead of enclosing function
- Chunking-level refactor needed: attribute call edges to their enclosing function entity at parse stage
- Would unlock major usability upgrade for impact analysis on React/TSX codebases

**Files to change:**
- `lib/elixir_nexus/chunker.ex` — attribute calls to enclosing function instead of module
- `lib/elixir_nexus/search/entity_resolution.ex` — post-hoc function refinement as fallback
- Tests: `find_all_callers` and `analyze_impact` should return function-level results

---

## 🟡 v1.10.0 — Medium Priority

### LiveComponent extraction (DX improvement)
- [ ] Split `lib/elixir_nexus_web/live/dashboard_live.ex` (448 lines) into smaller units
- [ ] Split `lib/elixir_nexus_web/live/vectors_live.ex` (664 lines) into smaller units
- **No functional changes** — purely code organization

### `find_module_hierarchy` children for function entities
- [ ] Populate `children` field with JSX renders (now tracked since v0.8.0) and nested function declarations
- [ ] Currently only works for module-level entities; should work for components too
- **Files:** `lib/elixir_nexus/search/queries.ex` (find_module_hierarchy/2)

### shadcn/ui dead code filtering
- [ ] Auto-exclude `components/ui/*.tsx` exports from `find_dead_code` results
- [ ] Or categorize as "unused UI primitive" separately from app-level dead code
- [ ] Current false positive rate: 214 dead functions, ~90% are shadcn exports
- **Files:** `lib/elixir_nexus/search/dead_code_detection.ex`

---

## 🟢 v1.10.0 — Nice-to-have

- [ ] History squash decision: squash v1.3.0–v1.3.3 into one commit (breaks orphaned tags, cleaner history)
- [ ] Quick-start dry run: verify `WORKSPACE=~/Documents docker-compose up -d` works end-to-end
- [ ] Framework convention internal functions filter (suppress `getMeta`/`getTorrent` in Next.js convention files)
- [ ] Variable/constant search boost in `search_code` (constants buried below functions in results)

---

## 📋 Earlier Backlog (v1.11.0+)

### Cross-language support gaps
- [ ] **Go imports:** Currently `{imports: 0, calls: 538}` — Go import statements not tracked
- [ ] **Go module hierarchy:** Method receivers not treated as parent-child relationships
- [ ] **Path aliases:** `@/` and tsconfig `paths` resolution (partially done; needs alias expansion)

### Graph visualization (D3)
- [ ] Grouped/clustered layout — file containers with collapsible modules (v0.8.0 → deferred)
- [ ] Filter framework noise in `get_graph_stats` top-connected (partially done; could improve)

### Upstream / OSS
- [ ] ExMCP timeout patch: upstream configurable timeout support or remove `sed` patch
- [ ] Secret audit: run `gitleaks` in CI (scheduled weekly)
- [ ] GitHub topics: verify `mcp`, `code-intelligence`, `tree-sitter`, `qdrant` are set

---

## Testing & CI

**Pre-push checklist (always run before pushing):**
```bash
mix compile --warnings-as-errors   # Zero warnings
mix format --check-formatted       # Formatted
mix test --exclude performance --exclude multi_project  # Tests pass
```

**Full test suite:**
```bash
mix test                           # All 728 tests
mix test --include performance     # + 32 benchmarks
```

---

## Session Notes

**2026-05-11:** Docker running v1.9.0 from Docker Hub. Verified all quick wins from prior sessions already shipped. Next focus: M1 (callers to function-level results) for high ROI on usability.

Council hub room: `elixir-nexus-oss-prep` tracks OSS/release readiness; `elixir-nexus-issues` tracks bugs/features.
