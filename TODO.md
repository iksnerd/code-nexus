# CodeNexus TODO

**Current version:** v1.18.13
**Status:** v1.18.13 shipped (2026-09-13), image built and pushed by CI, smoke-tested in-image. Previous: v1.18.12 shipped (2026-09-13) — `iksnerd/code-nexus:v1.18.12` + `:latest` (arm64) live on Docker
Hub, CI green, smoke-tested in-image: `reindex("weightless")` resolves to `/workspace4/weightless`
(24 Go files, 160 chunks, `error: null`) instead of the empty `/workspace/weightless`.

Previous: v1.18.11 shipped — `iksnerd/code-nexus:v1.18.11` + `:latest` (arm64) live on Docker
Hub. Verified against a real polyglot codebase (`gpt-alpha`: 283 Python files + TS/TSX frontend +
Go, 520 files total) — indexes cleanly, 3808 chunks, `error: null`. Python handling checked
directly: class/method extraction, `find_module_hierarchy` correctly resolves a class's own
methods, semantic `search_code` surfaces the right function for a natural-language query. 821
tests green, CI green.

## 🚧 Unreleased (on main) — dogfood fixes: data integrity, analysis accuracy, UI (2026-09-13)

From dogfooding v1.18.13 on elixir-nexus (Elixir), weightless (Go), control-stack (TS) and gpt-alpha
(Python), every result checked against grep, plus the UI in Chrome DevTools. Report pinned in Council
Hub room `code-nexus-dogfood-v1-18-12`.

- [x] **File watchers never stopped** (`Process.exit(pid, :normal)` is ignored): every reindex added a
  watcher, and edits in old projects were indexed into the active collection. Stopped with
  `GenServer.stop`, events guarded to watched roots (symlink-resolved for macOS FSEvents), and reconcile
  purges out-of-scope cached files. **After release: purge + reindex control-stack and gpt-alpha**, both
  contaminated in production.
- [x] **find_dead_code false positives**: Go 12/15 and TS 9/9 sampled hits were wrong. Real data now:
  weightless 42 → 5 (4 confirmed unused), control-stack services 16 → 0. Go package-level `var` blocks are
  now extracted (NIF keeps `var_spec_list`).
- [x] **.gitignore path patterns and nested .gitignore files** were ignored (a 40k-line bundle was indexed).
- [x] **find_module_hierarchy** resolved names project-wide and across languages; Python relative imports
  now resolve by path. Also: cache hydration turned `class`/`python` into `:function`/`nil`
  (`to_existing_atom`).
- [x] **Comments and strings counted as calls** (JS and Python content enrichment).
- [x] **Rankings**: builtins/stdlib calls (`len`, `Map.get`), test code, and generated files dominated
  `top_connected`/`critical_files`; the dashboard and graph now share the same fan-in.
- [x] **Graph queries answered empty during the async graph rebuild**; they now wait (bounded).
- [x] **find_all_callers merged same-named definitions**; callers carry `resolves_to`.
- [x] UI: Vectors "Re-index" indexed CodeNexus itself (and caused two flaky tests), wrong point/segment
  counts; dashboard tools card stale (8/12), no indexing progress; graph merged same-named folders, sized
  builtins as hubs, opened zoomed in, overlapping boxes; Tailwind play CDN replaced by a CLI build.
- [ ] Container build + Chrome verification before tagging.

## ✅ v1.18.13 — MCP HTTP transport fixes (2026-09-13)

Found while chasing "Claude Code shows authenticate for code-nexus". Claude Code's MCP log had 95
disconnect/reconnect cycles in a day plus "Failed to start server instance" at connect across every
session.

- [x] **Requests were serialized.** ExMCP's HTTP transport starts a temporary server per request with
  `start_link([])`, which registered the global module name. Any concurrent request (a client's parallel
  `tools/list` + `resources/list`, a second session, anything during a long reindex) failed. 19 of 20 in
  the new concurrency test. `start_link([])` now starts unnamed.
- [x] **SSE stream closed every 60s.** Cowboy's `idle_timeout` counts only incoming data, so heartbeats
  didn't help. `MCPServer.CowboyOptions.apply/0` sets `idle_timeout: :infinity` and the 32KB header limit
  at runtime (the Dockerfile header `sed` patch is gone).
- [x] **Unknown methods → HTTP 500.** Claude Code probes `server/discover`; now JSON-RPC `-32601`.
- [x] **`resources/list` rejected** (`size: null`, `mime_type`); normalized in `get_resources/0`.
- [x] **`get_status` `file_count`** was the chunk count; now files, plus `chunk_count`.
- Verified: 836 tests; live check script 6/6 on the local mix server and on a container built from the
  commit (discover, resources, 8KB header, 20 concurrent requests, 130s SSE hold); Claude Code reconnects
  clean. The "Authenticate" item in `/mcp` is Claude Code's generic option for HTTP servers, not a server
  signal.
- First release published by the CI `docker` job.

## ✅ Tag-only CI with Docker publish, pre-commit hook, gitleaks fix (2026-09-13, shipped with v1.18.13)

- [x] **CI runs only on `v*` tags** (plus manual `workflow_dispatch`). Removed the push/PR/weekly
  schedule triggers. `cancel-in-progress: false` so a release run is never cut off mid-push.
- [x] **Docker image published from CI.** New `docker` job (needs `test` + `secret-scan`) builds
  `linux/arm64` natively on `ubuntu-24.04-arm` with the `DOCKER_USERNAME`/`DOCKER_PASSWORD` secrets and
  pushes `:vX.Y.Z` + `:latest`. Fails if the tag doesn't match `VERSION`. Manual runs build only unless
  `publish` is ticked. `make docker.publish` stays as the local fallback. actionlint clean.
- [x] **Pre-commit hook** (`.githooks/pre-commit`, install with `make hooks`): gitleaks on staged
  changes, `mix format --check-formatted` on staged Elixir files, `mix compile --warnings-as-errors` when
  `lib/`/`config/`/mix files change. Tested: blocks an unformatted file and a planted fake token, passes a
  clean change.
- [x] **Secret scanning was a no-op since April.** `.gitleaks.toml` had only an `[allowlist]` and no
  `[extend] useDefault = true`, so gitleaks (CI's `gitleaks-action` included) ran with zero rules.
  Added the extend block. The allowlisted commit SHA was also stale after the history rewrite
  (`0e5a796` → `e8a5712`, the dev+test `secret_key_base` placeholder). Full history scan with real rules:
  227 commits, no leaks.
- [x] **Validated with a manual build-only run** (`gh workflow run ci.yml --ref main -f publish=false`,
  run 34763696317): test 87s, secret-scan 10s, docker 186s on the ARM runner (Rust NIF compiled
  natively, image not pushed). The first run of the real-rules secret scan failed on the dev
  placeholder under its pre-rewrite SHA `0e5a796`, still reachable via GitHub's `refs/pull/1/head` and
  `refs/pull/2/head`; both SHAs are now allowlisted. First push from CI happens on the next tag.

## ✅ Shipped in v1.18.12 — test isolation + bare-name resolution (2026-09-13)

- [x] **Weekly scheduled CI flake root-caused and fixed.** The scheduled run failed Aug 17 and Sep 7
  (passed Aug 24/31 on the same commit) on `delete_file/1 removes file from ChunkCache and GraphCache`
  (`indexer_file_test.exs:98`, `chunks_before` empty). The v1.18.8 theory below (dashboard tick timer)
  was wrong. Real cause: the `switch_collection_force/1` describe in `qdrant_client_test.exs`
  force-switched to `nexus_definitely_does_not_exist_xyz` and its `on_exit` restored only the
  `:qdrant_runtime` app env. Reads use that env; writes use the `QdrantClient` GenServer's own
  `state.collection`, which stayed on the fake name. When that test was the last collection switch in
  the random order, later upserts 404'd and nothing reached ChunkCache. Fix: `on_exit` calls
  `switch_collection_force(original_collection)`, which resets both. Verified with a throwaway test
  (old teardown leaves writes ≠ reads, new one keeps them in sync).
- [x] **Test collections no longer leak into the shared Qdrant.** Same env-only restore bug in
  `mcp_server_reindex_test.exs` left the GenServer pointed at a deleted per-test collection, which a
  later reset recreated. Fixed the teardown, renamed the `mcp_autoreindex_` tmp dir to
  `mcp_autoreindex_test_` (so `test_collection?/1` hides it), and `test_helper.exs` `after_suite` now
  sweeps suite-generated collections by exact name/regex. It never matches a broad `_test` pattern,
  since the suite shares Qdrant with real projects. Two back-to-back full runs: the first removed 8
  leaked collections and created none, the second changed nothing.
- [x] **Bare project name in several mounts.** `PathResolution.resolve_bare_name/2` now collects every
  matching mount. A match that is a real project (manifest/VCS marker or source dirs) wins over an
  empty dir of the same name, so `weightless` resolves to `~/GolandProjects/weightless` instead of the
  empty `~/www/weightless`. Several real matches return an error listing the host paths and asking for
  a full path. If no match looks like a project, the first one is kept (the indexer's 0-file error
  stays loud). 6 new tests in `path_resolution_test.exs`.
- [x] Docs: README drift pass (tool count, mount count, WORKSPACE_HOST in quick start, CLI Go
  version) with reference sections split into `docs/`; DOCKERHUB.md and CLAUDE.md path-resolution
  notes updated.

818 tests green (51 excluded), compile + format clean.

## ✅ Shipped in v1.18.11 — fix truncated content corrupting embedding batches (2026-08-11)

Found dogfooding on `gpt-alpha` (a real Python codebase, 283 `.py` files): indexing failed with
`"32 file(s) failed to store"` even though none of the source files had invalid UTF-8 — confirmed
by walking the whole repo tree and decoding every `.py` file.

**Root cause:** `Chunker.truncate_content/1` used `binary_part/3` — a raw byte offset — to cap
oversized chunk content at 4000 bytes. Any chunk larger than that with a multi-byte UTF-8
character (accented letters, em-dashes, smart quotes, emoji — common in docstrings/comments)
straddling the cutoff got its trailing byte(s) chopped off mid-character. The resulting
invalid-UTF-8 binary flowed into `prepare_for_embedding/1`'s output, which then crashed
`Jason.encode!` in the Ollama embedding request (`EmbeddingModel`) — silently dropping the entire
Broadway sub-batch (~32 unrelated files sharing that one Ollama call) from the index.

**Fix:** after the byte_size cutoff, back off byte-by-byte (bounded — UTF-8 sequences are at most
4 bytes) until `String.valid?/1` holds again. New regression test constructs content with an
em-dash positioned exactly at the 4000-byte boundary — reproduces the exact crash shape from the
wild. **File:** `chunker.ex`.

**Verified end-to-end against the released image**: re-reindexed `gpt-alpha` on v1.18.11 —
`error: null`, 520 files (up from 488, all 32 previously-dropped files now included), 3808 chunks.
`interp_viz.py` (the file whose content triggered the original crash) now indexes with 7 chunks,
no errors in the logs.

**Why this matters beyond gpt-alpha:** this bug affects any language, any large enough chunk with
non-ASCII text near the 4000-byte mark — likely to have silently dropped chunks in other projects
too, without any visible error to the user (just fewer search results than expected). Worth a
`find_dead_code`/chunk-count sanity pass on previously-indexed large projects if this class of
silent data loss matters for them.

## ✅ Shipped in v1.18.10 — fix reindex of a new project 404ing on every chunk (2026-08-11)

Found while verifying the v1.18.9 fix in-image: `reindex(path: "/app")` no longer hung, but the
reindex itself failed outright — `"87 file(s) failed to store"`, 0 chunks.

**Root cause:** `DirtyTracker` is a single global tracker, not scoped per collection. Switching to
a project whose Qdrant collection has never existed only creates it via
`prepare_reindex`/`reset_collection`, which runs solely on the `do_full_reindex` path.
`do_index_files_incremental` picks that path only when `DirtyTracker` is empty — but if any other
project was already reindexed earlier in the same server session, `DirtyTracker` still holds its
entries, so the new project incorrectly takes `do_partial_reindex` instead, which writes directly
to a collection that was never created. Every chunk store then 404s.

**Fix:** added `QdrantClient.ensure_collection/0` — idempotent create-if-missing (checks existence
first, never deletes/wipes, unlike `reset_collection/0`) — called from
`IndexManagement.ensure_collection_for_project` right after every collection switch, regardless of
which reindex path follows. Also removed `handle_info(:ensure_collection, ...)`, near-identical
create-collection logic that turned out to be dead code (nothing ever sent it). **Files:**
`qdrant_client.ex`, `mcp_server/index_management.ex`. New regression tests in
`qdrant_client_test.exs`.

**Verified locally and in-image:** reindexed elixir-nexus, then `/app` right after (the exact
original failure shape) — `error: null, chunks: 2463, files: 87`.

## ✅ Shipped in v1.18.9 — fix find_project_root climbing /app to / (2026-08-11)

`find_project_root/1` (`lib/elixir_nexus/mcp_server/path_resolution.ex`) treated any absolute path
whose *last segment* matched a common source-dir name (`lib`, `src`, `app`, …) as "caller passed a
subdir, climb to the parent." The container's own root is `/app` (Dockerfile `WORKDIR`), so
`reindex(path: "/app")` resolved to `/` and the Indexer hung walking the whole container
filesystem (`get_status` timed out at 5s, `GenServer.call` timeout).

**Fix:** don't climb past a directory that already looks like a project root (has
`mix.exs`/`package.json`/`go.mod`/`Cargo.toml`/`.git`/etc.) — it's the caller's intended target,
not a source subdir. 2 new regression tests in `path_resolution_test.exs`.

## ✅ Shipped in v1.18.8 — CI test-isolation fixes (2026-08-11)

- **`embed_and_store/1` test bug** — the "durable storage error" test asserted a real `econnrefused`
  but never forced one; it just hoped Qdrant was unreachable. Passed locally (no Qdrant running) but
  failed in CI (Qdrant service container up) because the write silently succeeded. Fixed by mutating
  the `QdrantClient` GenServer's own `state.url` via `:sys.replace_state` — its write handlers read
  state captured at init, not live Application config, so an `Application.put_env` override alone
  doesn't reach them. **File:** `test/elixir_nexus/indexing_helpers_test.exs`.
- **v1.18.7 shipped the same day** but its CI run failed on this bug (tag `v1.18.7` / commit
  `6a1235b` is public on Docker Hub only via GoReleaser CLI binaries — no Docker image was ever
  built from it, so it's not a live release artifact, just superseded).
- **Known flake (fixed 2026-09-13, see Unreleased — the theory below was wrong):** a second CI run on v1.18.8 failed once more, this time
  on `delete_file/1 removes file from ChunkCache and GraphCache` (`ChunkCache.all()` came back empty
  right after a synchronous `index_file` call returned). 5+ local reruns with different seeds stayed
  green; a CI rerun of the same commit also went green. Leading theory: `DashboardLive`'s 3s
  `handle_info(:tick, ...)` → `ProjectSwitcher.reload_from_qdrant()` timer outlives its own
  LiveView test and fires into a later, unrelated test's window, racing the global `ChunkCache`/
  `QdrantClient` state. Not root-caused — worth a proper fix (e.g. assert dashboard LiveView tests
  stop their socket in `on_exit`) before it costs another release cycle.
- **Path-resolution bug found while dogfooding** — `find_project_root/1` climbing `/app` to `/`.
  Fixed in v1.18.9, see below (and a second, deeper bug it uncovered, fixed in v1.18.10).

## ✅ Shipped in v1.18.5 — graph polish + dead-code bug fixes (2026-06-20)

- **Full-screen graph** — `/graph` breaks out of `max-w-7xl`; canvas fills `calc(100vh - 150px)`.
- **Boxes-separation** slider (spread clusters) + **link force strength 0.2→0.35** so the link-distance
  slider has visible authority (diagnosed live via chrome-devtools: it worked, 446→571, but was masked
  by cluster forces). **Files:** `layouts.ex`, `graph_live.ex`, `app.js`.
- **Dead-code bug (dogfooded on self)** — deeply-qualified calls (4+ module segments) never registered
  their callee suffix (the `case` only matched 2/3 segments), so a fn called via a long path was
  falsely dead. Now `List.last` for any depth. Plus: skip `*_controller.ex` (Phoenix router actions),
  add `child_spec`/`start_link` to OTP callbacks. **File:** `search/dead_code_detection.ex`.
- **Cleanup** — removed 2 unused `require Logger` (warns on all Elixir incl. CI's `--warnings-as-errors`).

## ✅ Shipped in v1.18.4 — purge race fix + graph shaping (2026-06-20)

- **Purge↔boot-reload race FIXED** — `purge` arms a one-shot `force_full_reindex`; the next reindex
  (sync or async) bypasses the seed-from-Qdrant dirty path and does a guaranteed full reparse, then
  clears the flag. Regression test re-seeds DirtyTracker after purge and asserts chunks come back.
  **Files:** `indexer.ex`, `indexer_directory_test.exs`.
- **More graph shaping controls** — min-connections slider (declutter: 500→230 nodes at min=5),
  Labels (Auto/All/None), Hide-variables toggle. Filters compose (edge-type + min-conn + node-type
  in one recompute). **Files:** `app.js`, `graph_live.ex`.

## ✅ Shipped in v1.18.3 — graph UX + analyze_impact fix + MCP descriptions (2026-06-20)

- **`analyze_impact` same-name fix** — keyed dedup + visited on `{name, file_path}` (was collapsing
  every `POST` route handler into one). `impact_analysis.ex`.
- **Graph: junk-blob root-cause fix** — `relationship_graph.resolve_ref_indexed` used a loose
  `String.contains?` fallback, so `i`/`cn` matched as a substring of nearly every ref → `i` got 4999
  phantom callers → huge blob. Now boundary-aware (dotted-suffix only) + skips refs ≤2 chars.
- **Graph noise filter** — `build_d3_graph` drops single/double-char locals + wrapper aliases.
- **Graph interactions** — clickable/isolatable package boxes; Select-mode toggle (Nodes/Boxes);
  edge-type filter (All/Calls/Imports/Contains); live Layout sliders (distance/repulsion/spacing/
  cluster). `app.js`, `graph_live.ex`. Validated live via chrome-devtools.
- **MCP tool descriptions** refreshed (layers, implementors, dead-code filtering).

### ✅ Observed during release — purge↔boot-reload race (fixed in v1.18.4)
After recreating the container, a `purge` issued while the boot auto-reload was still hydrating ETS
from Qdrant let the subsequent `reindex` re-seed DirtyTracker from stale Qdrant data — so most files
read as "unchanged" and were skipped, leaving a near-empty index (0 chunks). Recovery: purge again
once the boot settles, then reindex (got a clean 2192 chunks). Possible fix: have `reindex`/`purge`
wait for or invalidate the boot auto-reload, or skip DirtyTracker seeding immediately after a purge.

## Known issues

### ✅ Shipped in v1.18.3 — `analyze_impact` under-reported with same-named callers

Found via the MCP tool test (2026-06-20): `analyze_impact("createGcpConnector")` returned **2
affected** while `find_all_callers` found **4** — it dropped two of three `POST` route handlers.
`impact_analysis.ex` keyed both the caller dedup (`uniq_by(name)`) and the `visited` set on the bare
name, so all `POST`s collapsed to one and traversal stopped after the first (endemic in Next.js, where
every `route.ts` has GET/POST). Fixed by keying both on `{name, file_path}` (commit `2ea5b47`).
Regression test asserts all 3 same-named POST callers across files are counted.

### Carried-over housekeeping

- [x] **Test-collection leakage** into shared Qdrant — fixed 2026-09-13 (see Unreleased).
- [x] Re-enable CI once GitHub Actions quota resets — CI runs again (push + weekly schedule).

## ✅ Shipped in v1.18.2 — interface→implementor edges (Phase 2 #3) (2026-06-20)

The last Phase 2 increment: link a port interface to the functions/consts that satisfy it, resolving
the DI-wired-adapter dead-code false positives that survived the earlier passes.

- [x] **NIF** — `type_annotation` + `generic_type` made significant so a function's return type / a
  typed const's annotation reaches the extractor (the only structural "implements" signal in
  class-less hexagonal TS). NIF rebuilt; Docker rebuilds the Linux NIF. **File:** `native/.../lib.rs`.
- [x] **Extractor** — emits an implements edge (into `is_a`) from a return-type / typed-const
  annotation naming an interface; parameter types are excluded (they nest under `formal_parameters`).
  `function createOktaSyncAdapter(): SyncProviderAdapter` → `is_a ["SyncProviderAdapter", …]`.
  **File:** `parsers/javascript/entities.ex`.
- [x] **find_dead_code** — a function/const whose `is_a` names a known interface is a port
  implementor (DI-wired), not dead. Orphans implementing nothing still flagged. **File:** `search/dead_code_detection.ex`.
- [x] **find_module_hierarchy** — new `implementors` field: for an interface/struct, the entities
  that implement it (reverse edge). **File:** `search/module_hierarchy.ex`.
- [x] Also fixed a clause-grouping warning introduced in the Phase 1 `extract_contains` work.
- [x] Live-verified in-image: needed **purge + reindex** — incremental reindex hydrates unchanged
  files from Qdrant and won't re-parse, so a parser/NIF change requires a purge to take effect on an
  existing index. (Worth surfacing in `nexus-release` / client guidance.)

---

## ✅ Shipped in v1.18.1 — dashboard architecture-layers panel (2026-06-20)

The v1.18.0 layer breakdown was only in the `get_graph_stats` API response. v1.18.1 surfaces it in
the LiveView dashboard: an "Architecture Layers" panel with per-layer bars, derived the same way as
`Search.GraphStats.compute_layers/1` (root-relative paths via `ProjectConfig`) so UI and tool agree;
hides itself for flat projects. Refreshed two stale tool-card blurbs. Verified in-image — dashboard
HTML renders ports/adapters/application/domain/presentation/repositories on control-stack.
**Files:** `elixir_nexus_web/live/dashboard_live.ex` + test, `README.md`.

---

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
- [x] **Increment #3 — interface→implementor edges** (shipped in v1.18.2) (structural / naming match) for hexagonal
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

(Open items consolidated into the **Known issues** section at the top of this file —
Phase 2 #3 shipped in v1.18.2.)

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
- [x] **Bare-name multi-mount ambiguity** (fixed 2026-09-13, see Unreleased) — `weightless` exists under BOTH `/workspace` (www, empty) and `/workspace4` (GolandProjects, the real Go project). `resolve_bare_name` picks `/workspace` first. The loud 0-file error now makes this obvious, but consider: when a bare name matches multiple mounts, prefer the non-empty one or report the ambiguity. Low priority now that the failure is loud.

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
- [ ] **Path aliases:** `search/entity_resolution.ex` already applies tsconfig `compilerOptions.paths` and strips `@/`. Needs verification on a real aliased Next.js project before checking off

### Graph visualization (D3)
- [ ] Grouped/clustered layout — file containers with collapsible modules (v0.8.0 → deferred)
- [ ] Filter framework noise in `get_graph_stats` top-connected (partially done; could improve)

### Upstream / OSS
- [ ] ExMCP timeout patch: upstream configurable timeout support or remove `sed` patch. `ex_mcp` 1.3 is out (we pin 0.9.0); check whether it exposes the tool-call timeout and header-length options before a major-version bump
- [x] Secret audit: `gitleaks` runs in CI (`secret-scan` job, push + weekly schedule)
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
mix test                           # Full suite
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
