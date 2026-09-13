---
name: nexus-search-subsystem
description: ElixirNexus search subsystem architecture — hybrid query path, RRF fusion, graph re-ranking, entity resolution, callers/callees, dead-code detection, impact analysis. Use when modifying search behavior, adding a new query tool, or debugging why a search returns unexpected results.
---

# Search Subsystem

`lib/elixir_nexus/search/` is the largest subsystem after parsers — 12 files. `Search.Queries` is a thin facade; the real work is split across domain modules.

## Module map

| File | Responsibility |
|------|----------------|
| `queries.ex` | Thin facade that delegates to domain modules. Public API for MCP tool calls. |
| `data_fetching.ex` | Reads chunks from ChunkCache and shapes them into the search-result entity format (string-keyed map). All defensive `Map.get` access for optional fields. |
| `entity_resolution.ex` | Match entity names case-insensitively. `matches_entity_name?/2`, `find_entity_multi_strategy/2` (prefers exact names, non-test files, and type/module definitions when several match). `resolve_names/4` resolves relative to an entity: `:parents` within the same language family, nearest directory first, Python relative imports by file path; `:members` inside the entity's own file only. Don't use the project-wide `resolve_names/2` for hierarchy; it gave a Python class a TSX parent. |
| `caller_finder.ex` | `find_all_callers` — inverse of callees. Walks call edges from GraphCache. When several files define the queried name, tags each caller with `resolves_to` (qualifier → imports → nearest directory) and filters for a qualified query. |
| `callee_finder.ex` | `find_all_callees` — direct callees of a function. Uses `chunk.calls` list. |
| `impact_analysis.ex` | `analyze_impact` — transitive callers up to `depth`. Builds an `impact_tree` with leaves at the depth boundary. |
| `community_context.ex` | `get_community_context` — structurally coupled files via call edges + import edges, bidirectional. |
| `dead_code_detection.ex` | `find_dead_code` — public functions with zero callers. Framework filters (JS/TS conventions, Go `Test*`, Go standard-interface methods, Elixir callbacks). Receiver-qualified methods match calls through a variable. A candidate survives only if its name appears in no chunk except its own definition or one enclosing it: this catches functions passed as values and calls the extractor doesn't attribute (ternaries, object-literal methods). |
| `graph_stats.ex` | `get_graph_stats` — node/edge counts, top-connected, critical files (centrality). `top_connected/2` and `fan_in/1` are shared with the dashboard and graph page. Fan-in ignores builtin/stdlib calls (`Search.Builtins`), is qualifier-aware (`searchParams.get` doesn't credit a `GET` handler), and excludes test files; critical files skip test and generated files. |
| `builtins.ex` | Per-language builtins and stdlib qualifiers. Extend it when a builtin shows up as a hub. |
| `module_hierarchy.ex` | `find_module_hierarchy` — parents (behaviours/uses) + children (contains). File-path matching for TS/React components. |
| `graph_boost.ex` | Re-ranking layer that boosts results by call-graph centrality after initial retrieval. |
| `scoring.ex` | RRF (reciprocal rank fusion) constants and helpers used by the hybrid query. |

## Hybrid query flow (the search_code path)

```
search_code(query, limit) in mcp_server.ex
  → Search.search_code/2 (in search.ex, NOT search/queries.ex)
    → embed dense vector via EmbeddingModel.embed/1 (Ollama)
    → embed sparse vector via TFIDFEmbedder.embed/1 (TF-IDF feature hashing)
    → QdrantClient.hybrid_search/4 — server-side RRF prefetch fusion
    → Scoring.deduplicate/1 — dedup by (name, entity_type), keeping max-score
    → GraphBoost.apply_graph_boost/2 — re-rank by call-graph centrality
    → reject temp-prefix file paths
    → Enum.uniq_by (belt-and-suspenders re-dedup; cheap O(n))
    → Enum.sort_by score desc + Enum.take(limit)
```

**Why two dedups?** `Scoring.deduplicate/1` runs early so `GraphBoost`/graph-build operate on a smaller, unique set. The second `Enum.uniq_by` at step 6 is a guarantee, not a perf concern — added when the dedup test on CI flaked under heavy accumulated test-collection state. The `search_code` contract is "no two results with the same name+type", and this enforces it unconditionally.

Note: `search.ex` (NOT `search/queries.ex`) is the entry point for hybrid search. The `search/queries.ex` facade is for **graph-only queries** (callers, callees, impact, etc.) that don't need an embedded query vector.

## Concurrency safety

All search paths read from ETS (ChunkCache, GraphCache) directly — no GenServer.call bottleneck. The Qdrant collection name is pinned per-MCP-tool-call via `Process.put(:nexus_collection, ...)` in `IndexManagement.capture_collection/0`. This is captured at the start of each `handle_tool_call/3` so concurrent reindex operations can't swap the collection mid-query. See `qdrant_client.ex` `qdrant_state/0` for how the process dict overrides Application env.

## Defensive shape access

After v1.2.8's flake-fix, `data_fetching.ex` uses `Map.get(chunk, :parameters, [])` etc. for all optional chunk fields. Never use `chunk.parameters` directly — older chunks (or test fixtures) may be missing fields, and a `KeyError` cascades through every search call. New search code should follow this pattern.

## Adding a new query tool

1. Define a domain module in `lib/elixir_nexus/search/<your_tool>.ex`
2. Add a thin delegating function in `search/queries.ex` (keeps the facade pattern)
3. Wire to MCP via `deftool` + `handle_tool_call("your_tool", args, state)` in `mcp_server.ex`
4. Always call `IndexManagement.capture_collection()` at the start of the handler
5. Always call `IndexManagement.maybe_reindex_dirty(state)` before returning results — catches stale data from edits since last reindex
6. Use `ResponseFormat.json_reply/2` + `ResponseFormat.compact_results/1` for the response shape

## Common pitfalls

- **Score values aren't comparable across queries.** RRF-fused scores are relative. Don't filter by absolute score; rank then `take(limit)`.
- **Module-vs-function granularity.** Callers currently resolve to the enclosing module-level entity if no tighter function chunk matches. Open TODO; a chunking-level fix is needed to attribute calls to their tightest enclosing function.
- **Verify dead code against grep.** Sample a handful of hits on a real project before trusting a change: fixture tests passed while 12/15 Go and 9/9 TS hits were false (2026-09-13 dogfood).
- **Graph queries during a rebuild.** The graph rebuilds asynchronously after indexing (~47s on 6.8k chunks). `maybe_reindex_dirty` waits on `GraphCache.await_ready/1`; a new query tool that skips it answers from an empty graph.
- **GraphBoost can drown semantic relevance.** If you change the re-ranking weights, run `mix test test/elixir_nexus/hybrid_search_test.exs` — there's a dedup test that catches over-boosting.
