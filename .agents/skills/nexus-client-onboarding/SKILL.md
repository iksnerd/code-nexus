---
name: nexus-client-onboarding
description: First-look workflow for an unfamiliar codebase via the code-nexus MCP server. The right tool order to orient yourself in 30 seconds. Use when you've just landed in a new project and need to know its shape before answering anything specific.
---

# Codebase Onboarding via code-nexus

When you're dropped into an unfamiliar repo, don't grep blindly. Use the indexed graph in this order.

## The 30-second orient

```
1. reindex(<project-name>)              # if not already indexed
2. get_graph_stats()                    # shape: counts, top-connected modules, languages
3. load_resources(uri: "nexus://project/architecture")  # key modules + dependency structure
4. load_resources(uri: "nexus://project/hotspots")      # high fan-in/fan-out + dead code count
```

Now you know:
- What languages are present and how much of each
- The 10 most connected modules (these are the load-bearing structures)
- Which functions get called from everywhere (high fan-in — abstractions)
- Which functions call everything (high fan-out — orchestrators)

## Find a starting symbol

If the user asks "how does feature X work?", you don't have a function name yet. Use:

```
search_code("X", limit: 5)
```

Pick the highest-scoring result that matches the *intent* of X (not just keyword overlap). If the top result is a module, drill in:

```
find_module_hierarchy(entity_name: "TheModule")  # behaviours/uses + children
```

If the top result is a function, get its surroundings:

```
find_all_callees("the_func")   # what does it do?
find_all_callers("the_func")   # who depends on it?
get_community_context(file_path: "path/to/file.ex")  # structurally coupled files
```

## When the index is stale or missing

`reindex` is required before anything else when:
- You just cloned the repo
- The container restarted (no auto-create of default collection in v1.2.4+)
- A search returns 0 results that you know should exist

Auto-reindex on queries handles incremental file changes (SHA256-tracked dirty files), but only if the file watcher is set up after a `reindex` ran at least once.

## What `nexus://project/overview` tells you that you'd otherwise have to compute

`load_resources(uri: "nexus://project/overview")` gives you:
- File count, total chunks, graph node count
- Language breakdown (chunks per language)
- Entity types (function/module/class counts)

This is *not* in `get_graph_stats` — overview is more readable, get_graph_stats is more granular (top-connected lists, edge counts).

## Multi-project gotcha

Each project lives in its own Qdrant collection (`nexus_<name>`). When you `reindex(other-project)`, the active collection switches. Subsequent queries hit `other-project` only. To switch back, `reindex(<original>)` (data is preserved per collection — just switching which one is active).

If you need both at once, that's not supported — restart the workflow per project.
