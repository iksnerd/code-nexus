# CodeNexus TODO

**Current version:** v1.14.0 (async reindex, indexing progress in get_status)
**Status:** v1.14.0 tagged; 768 tests green (42 excluded)

---

## 🔧 In progress (uncommitted) — council-hub feedback fixes (2026-06-13)

Acting on `codenexus-feedback` #019ec14e (Go re-test on `weightless`) + `code-nexus-suggestions`.

- [x] **Loud 0-file index + `last_index_result`** — async reindex no longer reports silent success on an empty/wrong-mount result. `Indexer` records a terminal `last_index_result` (`files`, `chunks`, `languages`, `skipped`, `error`, `finished_at`) on every completion path; surfaced via `get_status`. Distinguishes never-ran (nil) / finished-empty (error) / finished-ok. **Files:** `indexer.ex`, `mcp_server.ex`. Tests added.
- [x] **Go `contains` regression (85 → 0)** — root-caused to a tree-sitter-go AST shape change. Three fixes:
  - NIF: added `parameter_list` to `is_significant_node` — method receivers were dropped (children of filtered nodes aren't promoted), so methods lost their `Type.` prefix and couldn't link to their struct. Restores `Storage.WritePiece` naming + method params.
  - NIF: capture `text` for string-literal kinds even when quote tokens make `child_count > 0` — fixes empty import paths.
  - Elixir: `extract_struct_fields` descends into the new `field_declaration_list` wrapper.
  - **Files:** `native/tree_sitter_nif/src/lib.rs` (NIF rebuilt), `parsers/go/entities.ex`. NIF + parser integration tests added.
- [x] **Go `imports` edges (0)** — same string-literal NIF bug; `ImportsPackage.extract_imports` now recovers paths, propagated to all entities' `is_a`. Verified end-to-end on `weightless`.
- [ ] **Bare-name multi-mount resolution** — `resolve_path` already scans all mounts in source (`path_resolution.ex`); the feedback ran against an older `:latest` image. Verify after next Docker rebuild.
- [ ] Rebuild + push Docker image (Linux NIF) and re-verify against `weightless` before closing the council-hub thread.

---

## ✅ Shipped in v1.11.5

- [x] **Keyword fallback deduplication** — `keyword_search_fallback` was returning raw ChunkCache results without dedup; fixed by applying `Scoring.deduplicate` + sort + limit (same as main path steps 4/6). Fixes scheduled CI failure on fresh Qdrant.
- [x] **Variable/constant search boost** — 1.15× score multiplier for `variable`/`constant` entities in final sort; constants no longer buried below functions.
- [x] **Convention-file data-fetching filter** — `getMeta`/`getTorrent`/`fetch*`/`load*`/`generate*` helpers in Next.js convention files now excluded from `find_dead_code` (same as PascalCase default exports). Generic helpers like `unusedHelper` still flagged.
- [x] **CI Node.js 24 opt-in** — `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: "true"` added before June 2 forced migration.

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

### LiveComponent extraction (DX improvement) ✅

- [x] Split `dashboard_live.ex` render (170 lines → 10) into 7 private function components: `status_bar`, `primary_stats`, `entity_language_grid`, `relationship_overview`, `activity_errors_section`, `mcp_tools_grid`, `page_footer`
- [x] Split `vectors_live.ex` render (260 lines → 10) into 8 private function components: `collection_stats`, `entity_type_dist_bar`, `actions_bar`, `filter_bar`, `points_table`, `pagination_controls`, `detail_modal`, `flash_notice`

**No functional changes** — purely code organization

### `find_module_hierarchy` children for function entities ✅
- [x] JSX renders now appear in children for function/method entities — PascalCase `calls` are resolved at query time; no reindex needed.
- [x] Nested function declarations — inner functions whose line range falls within the parent's range are now resolved as children at query time; no reindex needed.
- **Files:** `lib/elixir_nexus/search/module_hierarchy.ex`

### Go imports stats verification ✅
- [x] Traced full pipeline: GoExtractor → Chunker → GraphCache → graph_stats. `is_a` is populated and preserved at every stage; `filter_ast_noise` does not touch Go import paths. No bug found — code path is correct.

### Rust + Java extractor follow-ups
- [x] Rust `extract_params` — `self_parameter` fix shipped in v1.11.0
- [x] Go receiver type in method names — already done (Storage.WritePiece) since v1.10.0
- [ ] Java `extends_interfaces` super-interfaces extraction — verify on real Spring projects
- [ ] Promote Kotlin to dedicated `KotlinExtractor` if real-world usage shows GenericExtractor is too coarse

---

## 🟢 v1.11.0 — Nice-to-have

- [ ] History squash decision: squash v1.3.0–v1.3.3 into one commit (breaks orphaned tags, cleaner history)
- [ ] Quick-start dry run: verify `WORKSPACE=~/Documents docker-compose up -d` works end-to-end
- [x] Framework convention internal functions filter (suppress `getMeta`/`getTorrent` in Next.js convention files)
- [x] Variable/constant search boost in `search_code` (constants buried below functions in results)
- [x] Swift extractor — `property_declaration` now classified as `:variable`; shipped in v1.11.0
- [x] Prometheus `:summary` → `:distribution` (with `reporter_options: [buckets: [...]]`) — latency histograms now appear in `/metrics`
- [x] Skip-tiny-chunks filter — `chunk_entity/1` returns `[]` for content < 50 chars; removes one-liners/aliases with no semantic value
- [x] `.nexusignore` path normalization — `docs/internal` patterns now matched root-relative via `classify_dir_path/2`; indexer passes relative paths
- [x] Go struct module hierarchy — `GoExtractor` post-processes method entities to populate struct `contains` with receiver methods; `find_module_hierarchy("Storage")` now returns its methods as children

---

## 📋 Earlier Backlog (v1.12.0+)

### Cross-language support gaps
- [x] **Go module hierarchy:** Method receivers linked as struct children — shipped v1.11.0
- [ ] **Path aliases:** `@/` and tsconfig `paths` resolution (partially done; needs alias expansion)

### Graph visualization (D3)
- [ ] Grouped/clustered layout — file containers with collapsible modules (v0.8.0 → deferred)
- [ ] Filter framework noise in `get_graph_stats` top-connected (partially done; could improve)

### Upstream / OSS
- [ ] ExMCP timeout patch: upstream configurable timeout support or remove `sed` patch
- [ ] Secret audit: run `gitleaks` in CI (scheduled weekly — already wired)
- [x] GitHub topics: `mcp`, `code-intelligence`, `tree-sitter`, `qdrant` + 10 more — already set

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
mix test                           # All 763+ tests
mix test --include performance     # + 32 benchmarks
```

---

## Session Notes

**2026-06-13 (council-hub feedback session):** Acted on the Go re-test feedback (`codenexus-feedback` #019ec14e). (1) Silent 0-file reindex success → loud `last_index_result` in `get_status`. (2) Go `contains` regression 85→0 root-caused to a tree-sitter-go AST shape change: `parameter_list` was missing from the NIF significant-node list (receivers dropped, since children of filtered nodes aren't promoted), struct fields moved under `field_declaration_list`, and string-literal text was empty due to anonymous quote-token children. Fixed all three (NIF rebuilt for macOS host; Docker rebuilds Linux NIF). (3) Go `imports` edges were 0 from the same string-literal bug — now extract correctly. Note: the earlier "Go imports stats verification ✅ — no bug found" was a false negative; the bug was in the NIF, not the Elixir pipeline. 768 tests, 0 failures. NIF + parser integration tests added. Pending: Docker image rebuild/push + re-verify against `weightless`.

**2026-05-20 (quick wins):** GitHub topics already set. Go module hierarchy backlog item marked done (shipped v1.11.0). Nested function declarations added to find_module_hierarchy — inner functions whose line range falls within parent's range now appear as children at query time; no reindex needed. 2 new tests, 763 total, 0 failures.

**2026-05-19 (session fixes):** 5 backlog items cleared — Prometheus summary→distribution histograms with buckets; Chunker skip-tiny (<50 chars) filter; .nexusignore path normalization (root-relative classify_dir_path/2); Go struct module hierarchy (GoExtractor enriches struct contains with receiver methods); find_module_hierarchy JSX children for function entities (PascalCase calls resolved at query time). 771 tests, 0 failures (32 excluded).

**2026-05-18 (v1.11.5 shipped):** Search quality + dead code filter fixes — keyword fallback dedup (fixes scheduled CI failure), variable/constant 1.15× score boost, getMeta/getTorrent convention-file filter for find_dead_code, CI Node.js 24 opt-in. 753 tests green.

**2026-05-18 (v1.11.4 shipped):** Python extractor: content-enrichment pass for NIF depth-filtered calls — same fix as JS M1 but for Python: after AST extraction, checks each function's source content for bare from-imported symbols and adds the qualified call (mod.sym) when found. Fixes `render_variant` and other deeply nested calls (inside try/for) that the NIF misses at depth 20+. 759 tests.

**2026-05-18 (v1.11.3 shipped):** Python extractor: source-text fallback for parenthesized multi-line `from X import (a, b, c)` imports — `import_list` nodes are filtered by the NIF, so the AST path returned empty symbols; now reads raw source lines from `start_row` to closing `)` to recover them. Verified against `meta-ads-analysis`: `render_variant` callers now resolve correctly.

**2026-05-17 (v1.11.2 shipped):** Python extractor: `from X.Y import Z` now emits qualified calls (`X.Y.Z`) and correct `is_a` edges — fixes ~40/45 false-positive dead-code hits on projects using from-import chains. CallerFinder: drops module callers when function sibling is already present; DataFetching limit raised to 10k. 757 tests green.

**2026-05-17 (v1.11.0 shipped):** M1 fix — JS extractor now enriches function entities' calls with imported names that appear in source content (word-boundary regex). Rust `self_parameter` → `"self"` in params. GenericExtractor `property_declaration` → `:variable`. docker-compose hardened: `restart: unless-stopped`, Hub image only, 4 workspace mounts via `.env`. 754 tests green.

**2026-05-12 (v1.10.0 shipped):** Multi-arch image `iksnerd/code-nexus:v1.10.0` live. Live-verified Ruby/Kotlin/Swift/Rust/Java end-to-end against the rebuilt NIF — 5 langs, 26 chunks, 12 imports, 16 calls, 14 contains edges in a polyglot test fixture. Council hub `elixir-nexus-issues` updated (#019e18bb).

**Council Hub rooms:** `elixir-nexus-oss-prep` tracks OSS readiness; `elixir-nexus-issues` tracks bugs/features.
