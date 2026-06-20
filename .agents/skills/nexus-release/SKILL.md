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

**Paper cut — local Elixir newer than CI.** CI pins a specific Elixir/OTP
(`.github/workflows/ci.yml` → `ELIXIR_VERSION` / `OTP_VERSION`; currently 1.19.5 / 27).
A newer *local* Elixir (e.g. 1.20.x) runs a stricter set-theoretic type checker and can fail
`mix compile --warnings-as-errors` on **pre-existing** code (e.g. `dirs == []` always-false,
`get_embedding/1` inference) that the pinned CI version never flags. These are *not* regressions.
Before treating such a warning as a blocker, confirm it predates your change:

```bash
git stash && mix compile --force --warnings-as-errors 2>&1 | grep -oE "lib/[^ ]+\.ex:[0-9]+" | sort -u > /tmp/head.txt
git stash pop && mix compile --force --warnings-as-errors 2>&1 | grep -oE "lib/[^ ]+\.ex:[0-9]+" | sort -u > /tmp/mine.txt
comm -23 /tmp/mine.txt /tmp/head.txt   # empty = you added zero new warnings → not your blocker
```

If the diff is empty, the warning is an environment artifact; rely on the pinned-version CI (or,
when CI is unavailable, the published-image smoke test in step 8) as the authoritative gate. Don't
"fix" pre-existing type-checker noise as part of a release — it's scope creep and risks behavior change.

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

### CI unavailable (quota exhausted / Actions disabled) — local-only release

GitHub Actions minutes can run out. When CI can't run, do **not** wait on it (the runs may sit
`in_progress` forever or fail to start). Substitute a local gate instead:

1. The **step 1 pre-push checks already passed locally** (tests + format) — that is the substantive
   gate CI would have run. Confirm `mix test --exclude performance --exclude multi_project` is green
   on the exact committed tree.
2. Skip straight to step 7 (build) and step 8 (smoke test). **The published-image smoke test is the
   real backstop** — it builds the Linux NIF from scratch and boots the actual artifact, catching
   anything a green test suite wouldn't (NIF link errors, missing vendor JS, startup crashes).
3. Note in the release post that CI was skipped and why, and that the local gate + image smoke test
   stood in. Re-enable CI for the next release when quota resets.

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

# docker-compose.yml uses :latest — no edit needed, just start.
# Prefer a bare `up` so it reads the full .env (WORKSPACE + WORKSPACE_2..5 mounts).
# Passing only WORKSPACE=~/www on the CLI DROPS the other mounts.
docker-compose up -d

# Tail logs until "MCP HTTP server started" appears (30-60s)
docker-compose logs -f elixir_nexus
```

**Paper cut — recreate, don't restart.** To pick up the new `:latest`, the container must be
*recreated* (`docker-compose down && up -d`). `docker start <container>` reuses the OLD image and
silently tests nothing new. The mounts live in `.env` (`WORKSPACE`, `WORKSPACE_HOST`,
`WORKSPACE_2..5`, `WORKSPACE_HOST_2..5`) — compose reads them automatically, so a bare `up` keeps
the full multi-mount setup that an inline `WORKSPACE=...` would clobber.

Look for these lines — if they all appear the container is healthy:
```
Qdrant is healthy
Indexer started (Broadway pipeline, ...)
Running ElixirNexus.Endpoint with cowboy ... at 0.0.0.0:4100
MCP HTTP server listening on port 3002
```

Then do a minimal MCP round-trip: reindex a workspace project and run `search_code` or `get_graph_stats`. Only proceed to post-release once at least one reindex + search succeeds.

**Paper cut — verify the in-image NIF, not just "it booted".** The Docker build compiles a fresh
**Linux** tree-sitter NIF — a different binary from the macOS `.so` you tested locally (and the `.so`
is gitignored, so it's never in the commit). A clean boot only proves the NIF *loaded*, not that it
*parses correctly*. If the release touched `native/tree_sitter_nif/src/lib.rs` or any extractor,
assert real parser output in the round-trip — e.g. on a known project `get_graph_stats` shows
`edge_counts.contains > 0` and `find_module_hierarchy(<a known type>)` returns its members. Matching
the chunk/edge counts from your local run is the strongest signal the in-image NIF is correct.

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
