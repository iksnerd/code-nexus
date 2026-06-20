# CodeNexus TODO

**Current version:** v1.18.0 (analysis-quality fixes + architecture awareness)
**Status:** v1.18.0 shipped — `iksnerd/code-nexus:v1.18.0` + `:latest` (arm64) live on Docker Hub,
smoke-tested in-image against control-stack; 803 tests green (42 excluded). CI skipped (GitHub
Actions quota exhausted) — local gate + published-image smoke test stood in.

---

## ✅ Shipped in v1.18.0 — analysis quality + architecture awareness (2026-06-20)

Four phases, all live-verified against `control-stack` (hexagonal TS, 280 files / 2171 chunks) on the
published image. Headline wins: `get_graph_stats` is now deterministic, `contains` edges 0 → 820,
`find_module_hierarchy` works on TS interfaces/type aliases, and a derived `layers` breakdown shows
the hexagonal shape (ports/adapters/services/…). Release paper cuts captured in the `nexus-release`
skill (CI-down path, local-vs-CI warning discrepancy, recreate-don't-restart, in-image NIF check).

### Phase 0 — analysis-quality (acted on user report + live re-test)

Originally root-caused against `control-stack` (280 files, 2247 chunks). Root-caused
why the aggregate/ranking tools felt untrustworthy and fixed six issues. 771 tests green, format +
compile clean. **Not yet shipped (no Docker image cut).** See `elixir-nexus-issues` for the writeup.

- [x] **Non-deterministic `critical_files`** (the long-standing "centrality shifts between calls"
  report). `compute_critical_files` used `Enum.take_random` to pick 30 BFS sources, reseeded every
  call — two back-to-back `get_graph_stats` on control-stack returned different lists. Now selects
  the highest out-degree nodes deterministically and scales the sample to graph size.
  **File:** `search/graph_stats.ex`.
- [x] **Silent 2000-entity truncation** — `find_dead_code`, `get_community_context`, `analyze_impact`,
  `find_module_hierarchy`, `find_callees/callers` all called `get_all_entities_cached(2000)`; the
  in-memory ChunkCache was then truncated to an arbitrary 2000, dropping call edges (false dead-code
  positives, missing impact) on any project >2000 chunks. ChunkCache path now returns all entities
  (`:all`); the cap only bounds the Qdrant scroll fallback. **Files:** `search/data_fetching.ex` + 6 callers.
- [x] **`top_connected` ranked imports, not hubs** — degree counted `is_a` (imports) as outgoing and
  `incoming_count` was often 0, so provider/barrel modules (`ReactQueryProvider` 825) outranked real
  hubs like `cn`. Now degree = call/contains out + call fan-in; import edges excluded. **File:** `search/graph_stats.ex`.
- [x] **Destructuring/pattern noise in rankings** — `[canScrollNext, setCanScrollNext]`, `{ isMobile, state }`
  leaked into top_connected and community_context. Added a `pattern_name?` filter (names with `[`/`{`/`,`/space).
  **Files:** `search/graph_stats.ex`, `search/community_context.ex`.
- [x] **`get_community_context` import-noise** — coupling_score summed one "imports utils.ts" fact per
  component (sidebar.tsx scored 77 from a single relationship). Import edges now collapse to one per
  direction; score = distinct connections. **File:** `search/community_context.ex`.
- [x] **Dead-code false positives on Next.js** — lowercase convention exports (`manifest`, `sitemap`,
  `robots`) leaked through the filter; `*.test.*`/`*.spec.*` helper functions were flagged. Added a
  `name == basename` convention clause + `test_file?` skip. **File:** `search/dead_code_detection.ex`.
- [x] **Hotspots dead-code summary permanently "0 of 0"** — `nexus://project/hotspots` filtered
  `visibility == "public"`, but GraphCache nodes carried no `visibility` field. Added `visibility`
  to all three node-build paths (via `Map.get`, tolerating partial chunks) and aligned the filter to
  treat nil as public. **Files:** `graph_cache.ex`, `relationship_graph.ex`, `mcp_server/resources.ex`.
### Parser: TS interface/type containment + destructuring filter (2026-06-20)

Class-less (hexagonal) TS got **zero `contains` edges** — `find_module_hierarchy` was blind to ports
(interfaces) and domain types. Root cause: the NIF filtered the member-carrying nodes.

- [x] **NIF passes interface/type members** — `object_type` (body of `type X = {...}`) and
  `property_signature` (non-method members like `id: string`) added to `is_significant_node`.
  `interface_body` + `method_signature` already passed. NIF rebuilt (macOS `.so`; Docker rebuilds Linux).
  **File:** `native/tree_sitter_nif/src/lib.rs`.
- [x] **Extractor emits interface/type `contains`** — `extract_contains` now handles
  `interface_declaration` (→ interface_body members) and `type_alias_declaration` (→ object_type
  members), pulling property + method names. Verified end-to-end through the real NIF:
  `interface UserRepository` → `["findById","save","tableName"]`; `type DownloadOpts` →
  `["url","retries","onProgress"]`. **File:** `parsers/javascript/entities.ex`.
- [x] **Dropped destructuring pseudo-entities** — `const [open,setOpen] = useState()` / `const {x,y} = props`
  no longer become `variable` entities (the whole pattern was captured as a name, inflating counts +
  rankings). **File:** `parsers/javascript/entities.ex`. 774 tests green (+3).

### Architecture awareness — `.nexus.toml` + derive-first (decided 2026-06-20, in progress)

User decision: **derive-first, config overrides.** Nexus infers layers from directory conventions
(`core/ports`, `infrastructure`/`adapters`, `services`, `repositories`, `core/entities`) + interface→
implementor edges; an optional `.nexus.toml` overrides layer globs and declares `entry_points`
(which also kills dead-code false positives — route handlers, sitemap, DI-wired adapters).

- [x] **Increment #1 — `.nexus.toml` loader + `entry_points` → dead-code** (790 tests, +16).
  New `ElixirNexus.ProjectConfig` (`load/1`, `parse/1`, glob matcher, `entry_point?/2`); `toml ~> 0.7`
  added as an explicit dep. Loaded at reindex time (`mcp_server.ex`, after collection setup) and cached
  in Application env with the project root. `find_dead_code` excludes exports whose root-relative path
  matches an `entry_points` glob — finally kills the recurring FP class (route handlers, sitemap, DI
  adapters) *definitively and per-project*. Absent config = empty struct = no behavior change.
  **Files:** `project_config.ex` (new), `mcp_server.ex`, `search/dead_code_detection.ex`, `mix.exs`.
- [x] **Increment #2 — derive-first layer detection** (803 tests). New `ElixirNexus.Layers`
  (`classify/1`) infers a layer from directory conventions (ports / adapters·infrastructure /
  application·services / repositories / domain·core·entities / api / presentation / lib), checked
  most-specific-first. `ProjectConfig.layer_for/2` lets `[layers]` globs override. `get_graph_stats`
  now returns a `layers` breakdown (entities per layer), classified on root-relative paths.
  **Files:** `layers.ex` (new), `project_config.ex`, `search/graph_stats.ex`. Also fixed the
  `top_connected` `findControl ×6` dup (`uniq_by(name)`) found during live verify.
- [ ] **Increment #3 — interface→implementor edges** (structural / naming match) for hexagonal
  navigation — the last piece that would resolve the DI-adapter dead-code false positives the live
  run surfaced (`createOktaSyncAdapter`, RBAC fns, etc.).

### Docs (2026-06-20)

- [x] README: fixed drift (`Ten tools` → 12, added `purge` + `load_resources` rows; `~725` →
  `~800` tests; interface/type extraction marked Y for JS/TS); documented `.nexus.toml`
  (`entry_points` + `[layers]`) and the derive-first layer breakdown.
- [x] CLAUDE.md: added `project_config.ex` + `layers.ex` to the Key files table.

### ✅ Live-verified against control-stack via the local mix loop (2026-06-20)

Reindexed control-stack (280 files, 2171 chunks) on the local server with the rebuilt NIF. Confirmed:
- **Determinism** — two consecutive `get_graph_stats` are now byte-identical (`critical_files`:
  app-shell 647, sidebar 411, utils 282…). Scores are meaningful (was random 15/2/1).
- **`contains` edges 0 → 820** — interface/type/class members now in the graph.
- **`find_module_hierarchy` on ports works** — `RepositoryHost` → its members; `IntegrationRepository`
  → `create/update/delete/listByOrg/listByOrgAndProvider`. Was empty for every TS interface before.
- **`top_connected`** shows real domain hubs (findControl, evaluateGcpEvidence, createAwsConnector),
  not import-floods. Fixed a dup artifact: same-named entities collapsed via `uniq_by(name)` (was
  `findControl` ×6 — name-keyed fan-in credits every overload). **File:** `search/graph_stats.ex`.
- **Dead-code** — `manifest`/`sitemap` no longer flagged. Still ~54 hits dominated by DI-wired
  adapters (`createOktaSyncAdapter`, RBAC fns, `useSyncExternalStore` callbacks) — **this is the
  motivation for Phase 2 #2/#3** (layer + interface→impl edges) and `entry_points` config.

### Shipped + verified in-image (v1.18.0)

- [x] **Docker image cut + pushed** — `iksnerd/code-nexus:v1.18.0` + `:latest` (arm64), digest
  `sha256:7fb09c2c…`. Container recreated from the published image and smoke-tested: `contains` 820,
  `layers` breakdown (application 1018 / presentation 673 / adapters 151 / domain 115 / ports 23 / …),
  `find_module_hierarchy("IntegrationRepository")` → its members. Linux NIF builds in-image.
- [x] Phase 2 #2 (layer detection) — shipped (see above).

### Still open

- [ ] **Phase 2 #3 — interface→implementor edges** (structural / naming match). The last piece that
  would resolve the residual DI-wired-adapter dead-code false positives the live run surfaced
  (`createOktaSyncAdapter`, `createAwsSyncAdapter`, RBAC fns, `useSyncExternalStore` callbacks).
- [ ] **Test-collection leakage** into shared Qdrant — `nexus_definitely_does_not_exist_xyz`,
  `nexus_force_switched` still present (carried from the v1.17.0 follow-up).
- [ ] Re-enable CI once GitHub Actions quota resets.

---

## ✅ Shipped in v1.17.0 — graph representation + switching robustness (2026-06-13)

Plus, beyond the list below: package clustering with tinted container boxes +
labels, language-aware grouping (`group_for/1`), struct/method/interface colors +
legend, calmer cross-package edges, wider spacing, qualified cross-package call
resolution (no more isolated package boxes), and project/collection switching
robustness (boot resolver picks the largest real collection, NavHook hides
test/temp collections and no longer hijacks the active one, test-collection
cleanup). All verified live against weightless via the local mix loop.



Graph correctness + representation, all verified live via the local mix loop against weightless:

- [x] **Cold-ETS hydrate on reindex** — after a restart, reindexing a project with existing
  Qdrant data + unchanged files took the "skip embed" path and left ChunkCache/GraphCache
  empty → `get_graph_stats`/graph/search returned zeros. `hydrate_cold_caches/0` now reloads
  from Qdrant when ETS is cold, before the dirty check. **File:** `indexer.ex`.
- [x] **Struct usage edges (connect data structs)** — Go `composite_literal` (`Server{}`,
  `&Server{}`, `pkg.Opts{}`, `[]T{}`) now emits a usage edge from the enclosing function to
  the struct. NIF gaps fixed: `qualified_type` made significant, `unary_expression` made
  significant (`&T{}`), and `type_identifier`/`qualified_type`/`composite_literal` added to the
  depth>20 allow-list. Struct connectivity on weightless: **10/29 → 24/29**. Remaining 5 are
  package-level `var` literals / `var x T` decls / channel-element types (would need
  field/param/return-type edges). **Files:** `parsers/go/calls.ex`, `native/.../lib.rs` (NIF rebuilt).
- [x] **Graph viz colors + legend** — struct (amber), method (purple), interface, variable/
  constant now colored; legend gains Method + Struct. **Files:** `app.js`, `graph_live.ex`.
- [x] **Graph layout** — type-aware link distance (contains tight so methods cluster on their
  struct), structs/modules always labeled. **File:** `app.js`.
- [x] Tests: composite-literal usage edges (bare/pointer/qualified). 771 tests green.
- Note: "duplicate nodes" report was a false alarm — extra circles are glow rings on
  high-traffic nodes, not duplicate node groups (158 unique = 158 groups).

---

## ✅ Shipped in v1.16.1 — graph UI contains links (2026-06-13)

- [x] **D3 graph renders struct→method containment** — `build_d3_graph` matched `contains`
  entries by exact name, but `contains` stores bare child names (`TrackUsage`) while method
  nodes are receiver-qualified (`SwarmState.TrackUsage`), so 0 contains links drew (verified
  live: 75 calls + 2 imports + 0 contains on weightless). Resolver now also tries
  `"<parent>.<child>"`. **File:** `elixir_nexus_web/live/graph_live.ex`.

---

## ✅ Shipped in v1.16.0 — reindex reconciliation + purge (2026-06-13)

Acting on `code-nexus-feedback` #019ec226: **`reindex` was additive** — partial/incremental
reindex (after a restart, DirtyTracker seeded from Qdrant) re-embedded only dirty files and
never deleted files that dropped out of scope (deleted on disk or newly `.nexusignore`'d), so
stale nodes/vectors persisted and `get_graph_stats` never shrank.

- [x] **Reindex reconciles deletions** — both partial-reindex paths now call `purge_out_of_scope/1`:
  files in `DirtyTracker.known_files()` but not in the current scope get their Qdrant points +
  ChunkCache + GraphCache nodes deleted and are forgotten. Fixes stale top-connected test nodes
  and the chunk-count-not-recomputed secondary bug. **Files:** `indexer.ex`, `dirty_tracker.ex` (`known_files/0`).
- [x] **Explicit `purge` MCP tool** — wipes the current collection + caches for a clean slate
  (escape hatch; reindex auto-reconciles so it's rarely needed). **Files:** `mcp_server.ex`, `indexer.ex` (`purge/0`).
- [x] Tests: reconciliation (dropped file evicted) + `purge/0` clears index.

---

## ✅ Shipped in v1.15.0 — council-hub feedback fixes (2026-06-13)

Acting on `codenexus-feedback` #019ec14e (Go re-test on `weightless`) + `code-nexus-suggestions`.
Shipped + live-verified against weightless on `iksnerd/code-nexus:v1.15.0`:
`contains` 0 → **398**, `imports` 0 → **6398**, `find_module_hierarchy("SwarmState")`
returns fields + 12 receiver methods, bare-name `weightless` now returns a loud
0-file error instead of silent success.

- [x] **Loud 0-file index + `last_index_result`** — async reindex no longer reports silent success on an empty/wrong-mount result. `Indexer` records a terminal `last_index_result` (`files`, `chunks`, `languages`, `skipped`, `error`, `finished_at`) on every completion path; surfaced via `get_status`. Distinguishes never-ran (nil) / finished-empty (error) / finished-ok. **Files:** `indexer.ex`, `mcp_server.ex`. Tests added.
- [x] **Go `contains` regression (85 → 0)** — root-caused to a tree-sitter-go AST shape change. Three fixes:
  - NIF: added `parameter_list` to `is_significant_node` — method receivers were dropped (children of filtered nodes aren't promoted), so methods lost their `Type.` prefix and couldn't link to their struct. Restores `Storage.WritePiece` naming + method params.
  - NIF: capture `text` for string-literal kinds even when quote tokens make `child_count > 0` — fixes empty import paths.
  - Elixir: `extract_struct_fields` descends into the new `field_declaration_list` wrapper.
  - **Files:** `native/tree_sitter_nif/src/lib.rs` (NIF rebuilt), `parsers/go/entities.ex`. NIF + parser integration tests added.
- [x] **Go `imports` edges (0)** — same string-literal NIF bug; `ImportsPackage.extract_imports` now recovers paths, propagated to all entities' `is_a`. Verified end-to-end on `weightless`.
- [x] Rebuild + push Docker image (`v1.15.0` + `latest`, arm64) and re-verify against `weightless` — done, all four findings confirmed fixed live.
- [ ] **Bare-name multi-mount ambiguity** — `weightless` exists under BOTH `/workspace` (www, empty) and `/workspace4` (GolandProjects, the real Go project). `resolve_bare_name` picks `/workspace` first. The loud 0-file error now makes this obvious, but consider: when a bare name matches multiple mounts, prefer the non-empty one or report the ambiguity. Low priority now that the failure is loud.

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
