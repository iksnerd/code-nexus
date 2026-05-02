---
name: nexus-qdrant-patterns
description: ElixirNexus QdrantClient patterns — collection switching, the Process.put concurrent-read-safe trick, lazy create-on-reindex, hybrid search query shape, and per-project collection naming. Use when modifying Qdrant interaction, debugging "collection not found" errors, or understanding why search bypasses the GenServer.
---

# QdrantClient Patterns

`lib/elixir_nexus/qdrant_client.ex` is a GenServer fronting the Qdrant HTTP API, but **read paths bypass the GenServer mailbox** for concurrency. This is unusual; the patterns below explain why.

## State storage: 3 layers

The active connection state (`url`, `collection`) lives in three places, each one trumping the previous:

1. **`Application.get_env(:elixir_nexus, :qdrant_runtime)`** — set by `store_runtime_state/2` in `init/1` and on every collection switch. This is the canonical source of truth.
2. **GenServer state** — kept in sync with Application env. Only `handle_call`s use this directly.
3. **Process dictionary** (`Process.get(:nexus_collection)`) — pinned per-MCP-tool-call by `IndexManagement.capture_collection/0` at the start of each `handle_tool_call/3`. Overrides #1 for the duration of that tool call.

`qdrant_state/0` is the single read function used by all read-only paths. It reads Application env, then layers the process-dict override on top:

```elixir
defp qdrant_state do
  base = Application.get_env(:elixir_nexus, :qdrant_runtime, %{...})
  collection = Process.get(:nexus_collection) || base.collection
  %{base | collection: collection}
end
```

## Why the process-dict trick

Without it: agent A starts a long `reindex(project_a)` (collection switches to `nexus_project_a`). Mid-flight, agent B fires `search_code` against `project_b`. Agent B's search picks up the *currently active* collection — wrong project.

With it: every `handle_tool_call/3` calls `IndexManagement.capture_collection/0` which does `Process.put(:nexus_collection, active_collection())`. Even if a parallel reindex switches the global state, this tool call's reads stay pinned. The pin lives only within the calling process and dies when the call returns.

Also see v1.2.0 for the related concurrency-race fix: rejected `reindex` no longer swaps the active collection at all (`Indexer.busy?/0` pre-check in `mcp_server.ex`).

## Collection naming

`IndexManagement.derive_project_name/2` chooses the collection name. Priority order:

1. `display_path` (the user's bare name like `"council-hub"`) if it's a bare name (no slash) — that's the user's intent
2. `project_root` basename, unless it's a generic `/workspaceN` mount root
3. `display_path` basename for full host paths
4. `project_root` basename as last resort

When the project is a subdirectory of a single-project workspace mount (e.g. `/workspace4/mcp-server` under `WORKSPACE_HOST_4=/Users/yourname/council-hub`), `PathResolution.parent_mount_basename/1` returns `"council-hub"` and the collection becomes `nexus_council_hub__mcp_server` — disambiguates from any other project also named `mcp-server`.

Then `ensure_collection_for_project/2` normalizes: lowercase, replace non-`[a-z0-9_]` with `_`, trim leading and trailing underscores, slice to 60 chars. The trailing-trim is from v1.2.3 (was producing `nexus__` from paths ending in `.` or `_`).

## Lazy collection creation (v1.2.4+)

The default collection is **not** auto-created at boot in production. `QdrantClient.init/1` no longer schedules `:ensure_collection`. The first explicit `reindex(...)` triggers `ensure_collection_for_project/2` which calls `switch_collection_force/1`, which posts to Qdrant and 200/409 either creates or accepts.

**Test env exception:** `init/1` checks `Application.get_env(:elixir_nexus, :env) == :test` and schedules the auto-create. Tests rely on the default collection existing for setup-free queries. See `config/test.exs`.

This means a fresh container has only the explicit-reindex collections — no `nexus_app` duplicate of the same code that's been mounted at `/workspace/elixir-nexus` and indexed.

## Hybrid search query shape

`hybrid_search/4` posts to `/collections/<coll>/points/query` with a prefetch + RRF fusion structure:

```json
{
  "prefetch": [
    {"query": <dense_768>, "using": "semantic", "limit": <k>},
    {"query": <sparse>,    "using": "keyword",  "limit": <k>}
  ],
  "query": {"fusion": "rrf"},
  "with_payload": true,
  "limit": <final_limit>
}
```

The two prefetches each use a different vector space; Qdrant fuses with RRF server-side. Don't try to do this client-side — Qdrant's fusion handles different-magnitude scores properly.

## Switch flavors

- **`switch_collection_force/1`** — used by `IndexManagement.ensure_collection_for_project/2`. Updates Application env + creates the collection if missing. The "force" name is misleading — it does NOT delete; it ensures.
- **`switch_collection/1`** — used by `ProjectSwitcher.switch_project/1` (dashboard / explicit switch). Same effect.
- **No switch** — happens when `Indexer.busy?/0` returns true. The reindex handler returns the busy message without any state change.

## Read vs write paths

- **Read paths (search, scroll, get_point):** call `qdrant_state/0` directly, bypass GenServer. Concurrent reads scale.
- **Write paths (create, delete, upsert):** go through `GenServer.call(__MODULE__, ...)` — serialized through the GenServer mailbox. Upsert specifically has a 120s timeout (long batch writes during indexing).

## Common pitfalls

- **404 from missing collection** is now treated as empty result in `vectors_controller scroll` (v1.2.8). Search paths already fall back to keyword search on 404. Don't hard-fail on 404 from Qdrant in new code paths.
- **Don't add new GenServer.call paths for reads.** They bottleneck under concurrent MCP tool calls. Use `qdrant_state/0`.
- **Application env is process-global.** Tests that touch it should isolate via `setup` blocks or sequential execution (`async: false`). The `MCPServerQueryToolsTest` flake (fixed v1.2.8) was about this.
- **The 409 "already exists" on create is expected.** v1.2.1 downgraded it from `:warning` to `:debug`. Don't re-raise it.
