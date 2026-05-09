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

- `docs/DOCKERHUB.md` — update if image size, env vars, or setup changed
- `CLAUDE.md` — update if architecture, build steps, or key files changed
- `cli/README.md` — update if CLI commands, flags, or install steps changed

Do NOT maintain a separate `CHANGELOG.md` — use git log.

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
gh run list --limit 3 --repo iksnerd/code-nexus
```

Two workflows run on tag push:
- **CI** — Elixir tests (must pass before Docker build)
- **Release CLI** — GoReleaser builds `nexus` binaries and publishes a GitHub Release automatically

CI must show `completed / success` before building the Docker image. If it fails, fix the issue, push a new commit, and wait again. Never publish a Docker image from a failing commit.

The CLI GitHub Release is created automatically by GoReleaser — no manual step needed.

## 7 — Build and push Docker image (multi-arch)

```bash
docker buildx build --platform linux/arm64 \
  -t iksnerd/code-nexus:vX.Y.Z \
  -t iksnerd/code-nexus:latest \
  --push .
```

**Note:** We build `linux/arm64` only — the primary deployment target is Apple Silicon Macs. Add `linux/amd64` back if Linux server deployment is needed (it's slow — cross-compilation via QEMU).

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
| `docs/DOCKERHUB.md` | Tags section updated with new version |
| `cli/README.md` | Install URLs use correct tag format |

## Version history

`git log --oneline --tags` and the body of each `vX.Y.Z` tag commit are the
source of truth for what shipped. Don't maintain a changelog table here — it
drifts from git, and we already have the canonical history one `git log` away.
