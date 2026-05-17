# CodeNexus TODO — v1.12.0 Roadmap

**Current version:** v1.11.0 (M1 callers fix, Rust self_parameter, Swift property_declaration, docker-compose workspace mounts)
**Status:** v1.11.0 image live on Docker Hub (arm64), 754 tests green

---

## ✅ Shipped in v1.11.0

- [x] **M1: Callers resolve to enclosing function** — JS extractor enriches function entities' `calls` with imported names that appear in their source content; fixes `find_all_callers` returning the file-level module at `start_line: 0` instead of the enclosing function on React/TSX codebases
- [x] **Rust `self_parameter` fix** — `&self` / `&mut self` now correctly produces `"self"` in the parameters list (was silently empty before)
- [x] **Swift `property_declaration` fix** — GenericExtractor now classifies `property_declaration` as `:variable` instead of `:function`; eliminates false-positive function entities for top-level `let g = ...` bindings
- [x] **docker-compose workspace mounts** — `www`, `WebstormProjects`, `PyCharmProjects`, `GolandProjects` wired via `.env`; `restart: unless-stopped` added; `build: .` removed (Hub image only)

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

## 🟡 v1.12.0 — Medium Priority

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
- [x] Rust `extract_params` — `self_parameter` fix shipped in v1.11.0
- [ ] Java `extends_interfaces` super-interfaces extraction — verify on real Spring projects
- [ ] Promote Kotlin to dedicated `KotlinExtractor` if real-world usage shows GenericExtractor is too coarse

---

## 🟢 v1.11.0 — Nice-to-have

- [ ] History squash decision: squash v1.3.0–v1.3.3 into one commit (breaks orphaned tags, cleaner history)
- [ ] Quick-start dry run: verify `WORKSPACE=~/Documents docker-compose up -d` works end-to-end
- [ ] Framework convention internal functions filter (suppress `getMeta`/`getTorrent` in Next.js convention files)
- [ ] Variable/constant search boost in `search_code` (constants buried below functions in results)
- [x] Swift extractor — `property_declaration` now classified as `:variable`; shipped in v1.11.0

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

**2026-05-17 (v1.11.0 shipped):** M1 fix — JS extractor now enriches function entities' calls with imported names that appear in source content (word-boundary regex). Rust `self_parameter` → `"self"` in params. GenericExtractor `property_declaration` → `:variable`. docker-compose hardened: `restart: unless-stopped`, Hub image only, 4 workspace mounts via `.env`. 754 tests green.

**2026-05-12 (v1.10.0 shipped):** Multi-arch image `iksnerd/code-nexus:v1.10.0` live. Live-verified Ruby/Kotlin/Swift/Rust/Java end-to-end against the rebuilt NIF — 5 langs, 26 chunks, 12 imports, 16 calls, 14 contains edges in a polyglot test fixture. Council hub `elixir-nexus-issues` updated (#019e18bb).

**Council Hub rooms:** `elixir-nexus-oss-prep` tracks OSS readiness; `elixir-nexus-issues` tracks bugs/features.
