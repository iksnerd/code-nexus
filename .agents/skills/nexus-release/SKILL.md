---
name: nexus-release
description: ElixirNexus release checklist — pre-push checks, version bump, git tag, Docker Hub build and push. Use when cutting a new release (e.g. v1.3.4), shipping Docker images, or verifying a release is production-ready.
metadata:
  compatibility: ElixirNexus project only
---

# ElixirNexus Release Checklist

Follow these steps in order when cutting a new release.

## 1 — Pre-push checks (must all pass)

```bash
mix compile --warnings-as-errors   # Zero warnings required
mix format --check-formatted       # Auto-fix with: mix format
mix test --exclude performance --exclude multi_project
```

If any check fails, fix it before proceeding. Never tag a broken commit.

## 2 — Bump version

Edit the `VERSION` file (single source of truth — `mix.exs` reads it at compile time):

```
X.Y.Z
```

Follow semver:
- **patch** (1.0.0 → 1.0.1): bug fixes, test/infra changes, refactors — no new features
- **minor** (1.0.x → 1.1.0): new features, significant behaviour changes
- **major** (1.x → 2.0): breaking changes to MCP API or data formats

## 3 — Update docs (if needed)

- `README.md` changelog section — add entry for the new version
- `docs/DOCKERHUB.md` — update if image size, env vars, or setup changed
- `CLAUDE.md` — update if architecture, build steps, or key files changed
- `.agents/skills/nexus-release/SKILL.md` — update version history table

## 4 — Commit

Stage only intentional files (never `.env`, secrets, or `query_graph.exs`):

```bash
git add lib/ test/ mix.exs README.md docs/ .agents/  # adjust as needed
git commit -m "Bump version to X.Y.Z — short description of what changed"
```

## 5 — Tag and push

```bash
git tag vX.Y.Z
git push origin main
git push origin vX.Y.Z
```

## 6 — Wait for CI green

```bash
gh run list --limit 1 --repo iksnerd/code-nexus
```

CI must show `completed / success` before building the Docker image. If it fails, fix the issue, push a new commit, and wait again. Never publish a Docker image from a failing commit.

## 7 — Build and push Docker image (multi-arch)

```bash
docker buildx build --platform linux/amd64,linux/arm64 \
  -t iksnerd/code-nexus:vX.Y.Z \
  -t iksnerd/code-nexus:latest \
  --push .
```

**Important:** Always build for both `linux/amd64` and `linux/arm64`. Single-arch amd64 images crash under Rosetta on Apple Silicon Macs (telemetry NIF fails). Multi-arch ensures native execution on both Intel and ARM hosts.

The multi-stage Dockerfile handles NIF compilation automatically for each platform.

After push, verify the manifest landed: `docker pull iksnerd/code-nexus:vX.Y.Z`

## 8 — Smoke-test the container locally

Pull the freshly-pushed image and run it against the real stack to catch NIF, timeout, or startup regressions before announcing:

```bash
# Stop any running container first
docker-compose down

# Pull the new image (confirms the push landed correctly)
docker pull iksnerd/code-nexus:vX.Y.Z

# docker-compose.yml uses :latest — no edit needed, just start
WORKSPACE=~/www docker-compose up -d

# Tail logs until "MCP HTTP server started" appears (30-60s)
docker-compose logs -f elixir_nexus
```

Look for these lines — if they all appear the container is healthy:
```
Qdrant is healthy
Indexer started (Broadway pipeline, ...)
Running ElixirNexus.Endpoint with cowboy ... at 0.0.0.0:4100
MCP HTTP server listening on port 3002
```

Then do a minimal MCP round-trip: reindex a workspace project and run `search_code` or `get_graph_stats`. Only proceed to post-release once at least one reindex + search succeeds.

**Also verify the dashboard UI works:** open `http://localhost:4100` in a browser and check that LiveView connects (buttons should be interactive, not dead). If LiveView fails to connect, check the browser console for `LiveView is not defined` — this means vendor JS files are missing from the image. See the `priv/static/js/` row in the key files table below.

## 9 — Clean up old local images

Remove images from previous releases to reclaim disk space. Keep only `latest` and the new version tag (they share the same digest):

```bash
# List what's local
docker images | grep elixir-nexus

# Remove old version tags (adjust version list as needed)
docker rmi iksnerd/code-nexus:vOLD1 iksnerd/code-nexus:vOLD2
```

`latest` and `vX.Y.Z` will both point to the same digest — only one copy is stored on disk.

## 10 — Post-release (optional but recommended)

- Post to the council hub `elixir-nexus-issues` room: what shipped, what's still open
- Post to `elixir-nexus-oss-prep` if any OSS prep items were completed
- If fixing issues from council hub, mark them resolved or carry forward

## Key files to check before every release

| File | What to verify |
|------|----------------|
| `VERSION` | Version bumped correctly (mix.exs reads this file; changing only VERSION preserves Docker deps cache) |
| `lib/elixir_nexus/mcp_server.ex` | No debug logging left in, tool list accurate |
| `lib/elixir_nexus/qdrant_client.ex` | No hardcoded collection names or URLs |
| `docker-compose.yml` | Port, env vars, and image reference current |
| `.github/workflows/ci.yml` | Excluded tags (`@tag :nif`, `@tag :file_watcher`) still valid |
| `priv/static/js/` | Vendor JS (`phoenix.min.js`, `phoenix_live_view.min.js`) must be git-tracked (`git ls-files priv/static/`) — they're in `.gitignore` so won't auto-stage |
| `README.md` | Changelog entry for new version, test count accurate |
| `docs/DOCKERHUB.md` | Tags section updated with new version |

## Version history reference

| Version | Key changes |
|---------|-------------|
| v1.6.0  | Inclusive-first `detect_indexable_dirs/1` (set `NEXUS_INDEX_STRATEGY=curated` for old fast-path); `GET /health` returns `{mcp, qdrant, ollama, indexed_projects}` (200/503); `reindex` response now includes `languages: [{lang, file_count}]` and `skipped: {default_deny_*, gitignore_*, nexusignore_*, unsupported_extension}`; IgnoreFilter source-tagged via `classify_dir/2`/`classify_file/2`; fix `dir/` patterns being silently dropped from .gitignore/.nexusignore parsing; `get_graph_stats.project_path` falls back to active Qdrant collection name; sharper tool descriptions stating preconditions; fix Vector Store en-dash literal in `vectors_live.ex` |
| v1.5.1  | Fix `get_status` `indexed` field — was always `false` for new sessions even when cache populated; now uses `ChunkCache.count() > 0` as fallback |
| v1.5.0  | `.nexusignore` + `.gitignore` glob pattern support (file-level filtering, pre-compiled regexes, expanded default deny list); `get_status` MCP tool (project, Qdrant health, Ollama, collections); single-project workspace auto-default on `reindex` with no args |
| v1.4.11 | Fix 3 call-graph bugs: function definitions leaking into calls lists (`walk_calls` recursed into def signatures); `GraphCache.find_callers` substring matching causing false positives; duplicate entries in `find_all_callers` after entity refinement |
| v1.4.10 | Sharpen `get_community_context` and `find_dead_code` tool descriptions for agent discoverability |
| v1.4.9  | Increase Ollama batch size 32→96 (fewer HTTP round trips, ~30% faster indexing); `@external_resource "VERSION"` so version bumps auto-recompile without `--force` |
| v1.4.8  | Fix container crash — runtime Dockerfile stage now copies VERSION from builder (mix.exs calls File.read!("VERSION") at startup) |
| v1.4.7  | Move version to standalone `VERSION` file — `mix.exs` reads it so version bumps no longer bust the Docker deps cache layer; saves 5-10 min per release build |
| v1.4.6  | Fix Ollama timeout under concurrent load — Broadway embed batcher capped at 2 concurrent workers (was schedulers/2); recv_timeout raised 60s→180s |
| v1.4.5  | Fix Phoenix dashboard HTTP 431 (`protocol_options` in config.exs/dev.exs); fix Ollama cold-start mid-index (`keep_alive: "30m"` on all embed requests) |
| v1.4.4  | Fix MCP HTTP 431 disconnect loop — Dockerfile patches ex_mcp Cowboy `max_header_value_length` 4096→32768 so Claude Code's large headers don't trigger repeated disconnects |
| v1.4.3  | Fix active collection mismatch on startup (auto-resolve to first Qdrant collection); NavHook defensive realignment; graph auto-refresh on MCP switch; search results show active project; Vectors collection name fix; nil guard on delete-last-collection |
| v1.4.2  | Dockerfile: build with `MIX_ENV=prod` + `mix phx.digest` — fixes missing static manifest when running prod image |
| v1.4.1  | Block `/app` indexing in Docker mode (MCP + REST); filter `_test` collections from UI; Go dead-code Test*/Benchmark* filter; skill bundling tests; `make docker.publish.fresh` |
| v1.4.0  | Prometheus metrics at `GET /metrics` — all nexus telemetry events + BEAM VM stats via `telemetry_metrics_prometheus_core` |
| v1.3.5  | OSS prep: git history cleaned, `MIX_ENV: prod` in docker-compose, `.claude/skills` symlink fixed; CI test collection race condition fixed |
| v1.3.4  | Fix dev-mode code reloader wiping skill content at runtime (`COPY .agents` added to runtime stage so re-evaluated `@skills_dir` finds the source). Final fix in the v1.3.x skill-bundling chain. |
| v1.3.3  | Fix `.dockerignore *.md` blocking `SKILL.md` from build context (added `!.agents/**/*.md` exception) |
| v1.3.2  | First attempt to ship `.agents/` in image — added `COPY .agents .agents` to builder (incomplete: `.dockerignore` still blocked) |
| v1.3.1  | Restrict MCP-exposed skills to user-facing `nexus-client-*` only; ship `nexus-client-search-recipes`, `nexus-client-refactoring-workflow`, `nexus-client-onboarding` |
| v1.3.0  | Skills exposed as MCP resources via `nexus://skill/<name>` + `nexus://skills/index`; compile-time embedding from `.agents/skills/` |
| v1.2.9  | Image catch-up release (rolled up v1.2.8 + post-tag CI fixes) |
| v1.2.8  | CI fix: `EmbeddingModel.embed_batch/1` short-circuits in test env (saves ~10min per CI run); slimmed CI triggers (no tag-push) |
| v1.2.7  | Add Go convention dirs (`cmd/`, `internal/`, `pkg/`) to `@indexable_dirs` so monorepos with Go subprojects index correctly |
| v1.2.6  | Disambiguate sub-project collection names — `IndexManagement.derive_project_name/2` prefixes parent mount basename for single-project mounts (e.g. `nexus_council_hub__mcp_server` not `nexus_mcp_server`) |
| v1.2.5  | Monorepo source-dir detection — `detect_indexable_dirs/1` descends to depth 2 when nothing matches at depth 1 |
| v1.2.4  | Drop boot-time auto-create of default Qdrant collection (was producing a useless `nexus_app` duplicate); test env restores it for setup-free queries |
| v1.2.3  | Fix collection name for single-project mounts — derive from `display_path` not generic `/workspaceN`; trim trailing underscores |
| v1.2.2  | Single-project workspace mount support — `resolve_bare_name` matches mount basename when `WORKSPACE_HOST_N` points at a project root |
| v1.2.1  | Workspace mounts extended to 5 slots (`WORKSPACE_4`/`WORKSPACE_5`); user-friendly "busy" reindex error message naming the running project; quieter boot (`:debug` for expected 409 collection-exists); Docker image build moved from CI to local Makefile (`make docker.publish` multi-arch buildx); healthcheck switched from `curl` to `bash /dev/tcp` |
| v1.2.0  | Default embedding model switched to `embeddinggemma:300m` (override with `OLLAMA_MODEL`); fix concurrency race where rejected reindex still swapped the active Qdrant collection (`Indexer.busy?/0` pre-check); fix cold-start Ollama timeouts dropping chunks (retries + `warm_up/0` on supervisor start; configurable `:ollama_timeout`/`:ollama_retry_attempts`) |
| v1.1.0  | Multi-workspace Docker mounts — `WORKSPACE_2`/`WORKSPACE_3` vars + `/workspace2`/`/workspace3` container paths; bare project name resolution across all active mounts |
| v1.0.5  | Fix Qdrant test collection leak (on_exit cleanup), test splits (mcp_server/relationship_graph/indexer → 8 files), qdrant_client.ex domain sections, 20 new QdrantClient tests; 725 tests |
| v1.0.4  | Fix dashboard broken LiveView — vendor JS files (`phoenix.min.js`, `phoenix_live_view.min.js`) missing from Docker image; add static asset and graph_live tests; test collection cleanup via `ExUnit.after_suite` |
| v1.0.2  | Fix `load_resources` resource generators — entity types showing as `"unknown"` due to `"type"` vs `"entity_type"` key mismatch in GraphCache nodes; 13 new resource tests |
| v1.0.1  | Internal refactor — `queries.ex`, `mcp_server.ex`, `javascript_extractor.ex`, `go_extractor.ex` each split into focused sub-modules; 5 large test files split into 28; direct unit tests for `EntityResolution` and `PathResolution`; 714 tests |
| v1.0.0  | Server renamed to `code-nexus`, `"use client"`/`"use server"` directive metadata, tsconfig alias resolution, `OLLAMA_MODEL` env var, extended graph noise filter, reindex no-path warning, 3 new project-switching tests |
| v0.9.0  | MCP resources (4 resources + load_resources fallback tool), dynamic codebase knowledge from ETS |
| v0.8.0  | Concurrent QdrantClient reads, cross-project isolation, caller refinement to enclosing function, fuzzy callees, @/ alias resolution, reindex warning |
| v0.7.1  | Qdrant test collection cleanup, `delete_collection/1` added |
| v0.7.0  | 8 OTP/code quality fixes, Broadway error handling, ETS ownership, 15 agent skills |
| v0.6.0  | file_path null fix, project_path in stats, Docker 3.28GB → 588MB, CI green |
| v0.5.0  | D3 force-directed graph visualization |
| v0.2.0  | CI/CD, Makefile, formatter, Docker Hub publish |
