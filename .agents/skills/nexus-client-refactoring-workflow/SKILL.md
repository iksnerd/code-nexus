---
name: nexus-client-refactoring-workflow
description: Recipe for safely changing a function — `analyze_impact` → `find_all_callers` → review each caller. Covers the `depth` parameter, when to widen it, and how to read the impact tree. Use before any non-trivial rename or signature change.
---

# Refactoring Workflow

Before touching a function with non-trivial reach, walk the call graph instead of trusting `grep`. AST-parsed call edges have no false positives from comments or strings.

## The three-step recipe

```
1. analyze_impact(entity_name: "the_function", depth: 3)
   → see the blast radius — total_affected, affected_files, impact_tree
2. find_all_callers(entity_name: "the_function", limit: 50)
   → flat list of direct callers
3. For each caller, decide: passthrough rename, signature update, or compatibility shim
```

## `depth` parameter — what it actually means

`analyze_impact(depth: N)` walks transitive callers up to N levels:

- `depth: 1` — direct callers only (same as `find_all_callers`)
- `depth: 2` — callers + callers-of-callers
- `depth: 3` (default) — usually enough for "is this safe?"
- `depth: 5+` — for entry-point or framework-internal functions where the blast radius is wide

If `total_affected` keeps growing every time you bump `depth`, the function has wide reach — break the change into smaller pieces.

## Reading `impact_tree`

`impact_tree` is a nested map. Each level is a hop further from the changed function. A node with no children means "this caller has no callers itself in the index" (a leaf — likely an entry point, test, or external surface).

If a leaf is a test file, that's a **good** signal — the change is well-covered.
If many leaves are public exported functions, you have an external API change.

## When `find_all_callers` returns the wrong granularity

The current implementation resolves to the enclosing module-level entity if no tighter function chunk matches. So you may see `MyModule` instead of `MyModule.func`. The `file_path` and `start_line` are accurate either way — open the file at that line to see the actual caller.

## Worked example

Renaming `Indexer.busy?/0` → `Indexer.indexing?/0`:

```
analyze_impact("busy?", depth: 3)
  → total_affected: 4, files: [mcp_server.ex, indexer.ex, mcp_server_test.exs]
find_all_callers("busy?")
  → [MCPServer.handle_tool_call/3 (mcp_server.ex:318), ...]
```

→ 4 sites, all in 3 files. Safe. Rename and update each call site. Re-run `find_all_callers("indexing?")` after to verify nothing was missed.

## Don't skip the index step

If you've changed code and **haven't** run `reindex` since, the call graph is stale. Auto-reindex on queries handles dirty files (SHA256-tracked), but only if the file watcher is set up. After a clone or container rebuild, run `reindex` once.
