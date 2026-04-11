---
name: nexus-release
description: ElixirNexus release checklist — pre-push checks, version bump, git tag, Docker Hub build and push. Use when cutting a new release (e.g. v1.1.0), shipping Docker images, or verifying a release is production-ready.
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

Edit `mix.exs` line 7:

```elixir
version: "X.Y.Z",
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
  -t iksnerd/elixir-nexus:vX.Y.Z \
  -t iksnerd/elixir-nexus:latest \
  --push .
```

**Important:** Always build for both `linux/amd64` and `linux/arm64`. Single-arch amd64 images crash under Rosetta on Apple Silicon Macs (telemetry NIF fails). Multi-arch ensures native execution on both Intel and ARM hosts.

The multi-stage Dockerfile handles NIF compilation automatically for each platform.

After push, verify the manifest landed: `docker pull iksnerd/elixir-nexus:vX.Y.Z`

## 8 — Smoke-test the container locally

Pull the freshly-pushed image and run it against the real stack to catch NIF, timeout, or startup regressions before announcing:

```bash
# Stop any running container first
docker-compose down

# Pull the new image (confirms the push landed correctly)
docker pull iksnerd/elixir-nexus:vX.Y.Z

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
docker rmi iksnerd/elixir-nexus:vOLD1 iksnerd/elixir-nexus:vOLD2
```

`latest` and `vX.Y.Z` will both point to the same digest — only one copy is stored on disk.

## 10 — Post-release (optional but recommended)

- Post to the council hub `elixir-nexus-issues` room: what shipped, what's still open
- Post to `elixir-nexus-oss-prep` if any OSS prep items were completed
- If fixing issues from council hub, mark them resolved or carry forward

## Key files to check before every release

| File | What to verify |
|------|----------------|
| `mix.exs` | Version bumped correctly |
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
