# TODO

## Auto-reindex on file changes

- [ ] File watcher that incrementally updates the index on save/delete — deleted files still appear in results until manual reindex, which makes the data untrustworthy
- [ ] At minimum, mark deleted files as stale and exclude from query results; ideally remove their chunks from Qdrant and ETS on detection

## TypeScript module resolution

- [ ] `find_module_hierarchy` only matches exact module names (e.g. `billing`) — can't find `BillingPage`, `billing-fallback`, or `billing-plans` by component/file name
- [ ] TS projects use file-based modules — resolve both the default export name and the filename/path as module identifiers
- [ ] Handle re-exports and barrel files (`index.ts` that re-export from subdirectories)

## Import graph tracking

- [ ] **`get_community_context` coupling direction** — returned 0 coupled files for `billing-fallback.tsx` even though landing page and billing page both import it. Only tracks outgoing call edges, not incoming imports. "Who imports this component?" is the most common question in React codebases.
- [ ] **`analyze_impact` should follow imports, not just calls** — `PLAN_DEFINITIONS` showed 0 impact despite 2 files importing it. In TS, the import graph IS the dependency graph. A constant changing shape breaks consumers even without function calls.
- [ ] **Cross-file type dependency tracking** — if `PlanId` changes from `['starter', 'professional', 'enterprise']` to add a tier, which files break? Can't answer today because we track calls, not type references.

## Graph analysis features

- [ ] **Hot path / centrality score** — `get_graph_stats` shows top connected nodes, but add a "most critical files" ranking using betweenness centrality (everything flows through them). Tells you where a bug causes the most damage.
- [ ] **Dead code detection** — "show me all exported functions with zero callers." Proactively flag unused exports (e.g. `getFeatureAccess`, `canAddIntegration` were exported but never called).

## Dashboard

- [ ] Fix UTC timestamps — display dates in user's local timezone instead of raw UTC
- [ ] Add ability to delete Qdrant collections from the dashboard UI (they accumulate over time with project switching)

## Testing / Robustness

- [ ] Improve test coverage and robustness around project switching (switching collections, ETS reload, file watcher re-wiring)
- [ ] Edge cases: switching while indexing is in progress, switching to a deleted collection, rapid successive switches

---

**Core insight:** The graph engine is solid. The gaps are mostly about TypeScript idioms (imports > calls, file-based modules, type references) vs the Elixir model it was built for.
