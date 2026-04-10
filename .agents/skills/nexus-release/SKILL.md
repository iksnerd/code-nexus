---
name: nexus-release
description: ElixirNexus release checklist — pre-push checks, version bump, git tag, Docker Hub build and push. Use when cutting a new release (e.g. v0.8.0), shipping Docker images, or verifying a release is production-ready.
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
- **patch** (0.7.0 → 0.7.1): bug fixes, test/infra changes, no new features
- **minor** (0.7.x → 0.8.0): new features, significant behaviour changes
- **major** (0.x → 1.0): breaking changes to MCP API or data formats

## 3 — Update docs (if needed)

- `README.md` changelog section — add entry for the new version
- `docs/DOCKERHUB.md` — update if image size, env vars, or setup changed
- `CLAUDE.md` — update if architecture, build steps, or key files changed

## 4 — Commit

Stage only intentional files (never `.env`, secrets, or `query_graph.exs`):

```bash
git add lib/ test/ mix.exs README.md docs/  # adjust as needed
git commit -m "Bump version to X.Y.Z — short description of what changed"
```

## 5 — Tag and push

```bash
git tag vX.Y.Z
git push origin main
git push origin vX.Y.Z
```

## 6 — Build and push Docker image

```bash
docker buildx build --platform linux/amd64 \
  -t iksnerd/elixir-nexus:vX.Y.Z \
  -t iksnerd/elixir-nexus:latest \
  --push .
```

The multi-stage Dockerfile handles NIF compilation automatically. Expected image size: ~588MB.

After push, verify on Docker Hub: `docker pull iksnerd/elixir-nexus:vX.Y.Z`

## 7 — Post-release (optional but recommended)

- Update the council hub `elixir-nexus-issues` room with what shipped and what's still open
- Update the `elixir-nexus-oss-prep` room if any OSS prep items were completed
- If fixing issues from council hub, mark them resolved or carry forward

## Key files to check before every release

| File | What to verify |
|------|----------------|
| `mix.exs` | Version bumped correctly |
| `lib/elixir_nexus/mcp_server.ex` | No debug logging left in, tool list accurate |
| `lib/elixir_nexus/qdrant_client.ex` | No hardcoded collection names or URLs |
| `docker-compose.yml` | Port, env vars, and image reference current |
| `.github/workflows/ci.yml` | Excluded tags (`@tag :nif`, `@tag :file_watcher`) still valid |

## Version history reference

| Version | Key changes |
|---------|-------------|
| v0.8.0  | Concurrent QdrantClient reads, cross-project isolation, caller refinement to enclosing function, fuzzy callees, @/ alias resolution, reindex warning |
| v0.7.1  | Qdrant test collection cleanup, `delete_collection/1` added |
| v0.7.0  | 8 OTP/code quality fixes, Broadway error handling, ETS ownership, 15 agent skills |
| v0.6.0  | file_path null fix, project_path in stats, Docker 3.28GB → 588MB, CI green |
| v0.5.0  | D3 force-directed graph visualization |
| v0.2.0  | CI/CD, Makefile, formatter, Docker Hub publish |
