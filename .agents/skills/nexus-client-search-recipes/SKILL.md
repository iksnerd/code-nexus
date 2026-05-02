---
name: nexus-client-search-recipes
description: Query patterns for `search_code` — when natural language wins over exact names, when to fall back to grep, and how to phrase intent-based queries. Use before reaching for grep/find on an indexed codebase.
---

# Search Recipes for `search_code`

`search_code` is **hybrid**: dense semantic embeddings + TF-IDF keyword + call-graph centrality re-ranking. Different query styles unlock different parts.

## Query style by intent

| You want… | Phrase it as… | Why |
|-----------|---------------|-----|
| Code that *does* something conceptually | Natural-language description: `"error handling in HTTP client"`, `"auth middleware for API routes"` | Dense semantic vector wins — exact words don't have to appear |
| A specific function/symbol you half-remember | The likely name, e.g. `"embed_batch"`, `"normalizeQuery"` | Name match + keyword scoring rank it first |
| A pattern across files | The pattern as code: `"def handle_call({:fetch"`, `"useEffect(() =>"` | Keyword + content match |
| Something tagged with a directive | The directive itself: `"use server"`, `"use client"` (Next.js) | Directive metadata is indexed at file level |

## When to use grep instead

- You need **every** occurrence, not the top-K. `search_code` returns ranked results, capped by `limit`. `grep` is exhaustive.
- You're matching a literal string in **comments or strings** — `search_code` indexes parsed AST entities, so non-code text isn't always reachable.
- You're outside an indexed project (no `reindex` ran). Without an index, `search_code` falls back to TF-IDF only.

## Tuning

- **`limit`** defaults to 10. Bump to 20–50 when surveying. Keep low (3–5) when feeding results into another tool call.
- The score field is RRF-fused; absolute values aren't comparable across queries. Use relative ordering only.

## Cross-language gotchas

- Symbol matching is **case-insensitive** and supports short names. `embed_batch` matches `ElixirNexus.EmbeddingModel.embed_batch/1`.
- Go uppercase-public convention is preserved — `MyFunc` (exported) vs `myFunc` (unexported) both resolve.
- TS path-alias imports like `@/components/Button` resolve via `tsconfig.json` `compilerOptions.paths`.

## Common shapes

- **"Find code related to X"** → `search_code "X"` with limit 10
- **"Where is the auth flow?"** → `search_code "authentication middleware"` then `get_community_context` on the top result's file
- **"What handles this error?"** → `search_code "<exact error message words>"` — TF-IDF picks up literal strings in throw/raise/log calls

If your first query returns junk, try one of:
1. Reframe as intent (`"X"` → `"why X happens"` / `"flow that produces X"`)
2. Reframe as code (`"how to Y"` → a likely function name)
3. Drop to `find_all_callees`/`find_all_callers` if you have a starting symbol
