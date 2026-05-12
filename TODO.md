# CodeNexus TODO — v1.11.0 Roadmap

**Current version:** v1.10.0 (Ruby NIF fix, Kotlin + Swift, dedicated Rust + Java extractors, shadcn/ui dead-code filter)
**Status:** v1.10.0 image live on Docker Hub (arm64), 749 tests green

---

## ✅ Shipped in v1.10.0

- [x] **Ruby NIF wiring** — `tree-sitter-ruby` 0.23 added; `.rb` files were silently producing 0 chunks before
- [x] **Kotlin support** — `.kt` / `.kts` via `tree-sitter-kotlin-ng` 1.1, GenericExtractor
- [x] **Swift support** — `.swift` via `tree-sitter-swift` 0.6 (0.7 ships ABI 15 — incompatible with tree-sitter 0.24)
- [x] **RustExtractor** — promoted from GenericExtractor: `use` imports, `impl` method names (`Greeter.hello` not bare `hello`), `pub` visibility, `name!` macro invocations
- [x] **JavaExtractor** — promoted from GenericExtractor: scoped imports, `method_invocation` calls, package declaration, supertype extraction, modifier-based visibility
- [x] **NIF significant-node expansion** — `visibility_modifier`, `macro_invocation`, Rust `use_*` family, Ruby `body_statement`, Kotlin/Swift declarations
- [x] **shadcn/ui dead-code filter** — `components/ui/*.{tsx,jsx}` auto-excluded from `find_dead_code` (~90% false-positive reduction on Next.js + shadcn projects)
- [x] **README polyglot table refresh** — 10 languages × 14 capability columns

---

## 🔴 v1.11.0 — High Priority

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

## 🟡 v1.11.0 — Medium Priority

### LiveComponent extraction (DX improvement)
- [ ] Split `lib/elixir_nexus_web/live/dashboard_live.ex` (448 lines) into smaller units
- [ ] Split `lib/elixir_nexus_web/live/vectors_live.ex` (664 lines) into smaller units
- **No functional changes** — purely code organization

### `find_module_hierarchy` children for function entities
- [ ] Populate `children` field with JSX renders (now tracked since v0.8.0) and nested function declarations
- [ ] Currently only works for module-level entities; should work for components too
- **Files:** `lib/elixir_nexus/search/queries.ex` (find_module_hierarchy/2)

### Go imports stats verification
- [ ] Council Hub feedback reported `{imports: 0, calls: 538}` on Go projects
- [ ] Code path through `is_a` looks correct; needs reproduction on a real Go codebase
- [ ] If still broken, fix `GoExtractor` to surface imports in graph stats correctly

### Rust + Java extractor follow-ups
- [ ] Rust `extract_params` — currently misses some patterns (self_parameter handling)
- [ ] Java `extends_interfaces` super-interfaces extraction — verify on real Spring projects
- [ ] Promote Kotlin to dedicated `KotlinExtractor` if real-world usage shows GenericExtractor is too coarse

---

## 🟢 v1.11.0 — Nice-to-have

- [ ] History squash decision: squash v1.3.0–v1.3.3 into one commit (breaks orphaned tags, cleaner history)
- [ ] Quick-start dry run: verify `WORKSPACE=~/Documents docker-compose up -d` works end-to-end
- [ ] Framework convention internal functions filter (suppress `getMeta`/`getTorrent` in Next.js convention files)
- [ ] Variable/constant search boost in `search_code` (constants buried below functions in results)
- [ ] Swift extractor — current GenericExtractor over-extracts top-level bindings (e.g. `let g = ...` produces a `g` function entity)

---

## 📋 Earlier Backlog (v1.12.0+)

### Cross-language support gaps
- [ ] **Go module hierarchy:** Method receivers not treated as parent-child relationships
- [ ] **Path aliases:** `@/` and tsconfig `paths` resolution (partially done; needs alias expansion)

### Graph visualization (D3)
- [ ] Grouped/clustered layout — file containers with collapsible modules (v0.8.0 → deferred)
- [ ] Filter framework noise in `get_graph_stats` top-connected (partially done; could improve)

### Upstream / OSS
- [ ] ExMCP timeout patch: upstream configurable timeout support or remove `sed` patch
- [ ] Secret audit: run `gitleaks` in CI (scheduled weekly — already wired)
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
mix test                           # All 749 tests
mix test --include performance     # + 32 benchmarks
```

---

## Session Notes

**2026-05-12 (v1.10.0 shipped):** Multi-arch image `iksnerd/code-nexus:v1.10.0` live. Live-verified Ruby/Kotlin/Swift/Rust/Java end-to-end against the rebuilt NIF — 5 langs, 26 chunks, 12 imports, 16 calls, 14 contains edges in a polyglot test fixture. Council hub `elixir-nexus-issues` updated (#019e18bb).

**Council Hub rooms:** `elixir-nexus-oss-prep` tracks OSS readiness; `elixir-nexus-issues` tracks bugs/features.
