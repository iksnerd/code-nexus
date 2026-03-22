# TODO

## Auto-reindex on file changes

- [x] File watcher that incrementally updates the index on save/delete — deleted files still appear in results until manual reindex, which makes the data untrustworthy
- [x] At minimum, mark deleted files as stale and exclude from query results; ideally remove their chunks from Qdrant and ETS on detection

## TypeScript module resolution

- [x] `find_module_hierarchy` only matches exact module names (e.g. `billing`) — can't find `BillingPage`, `billing-fallback`, or `billing-plans` by component/file name
- [x] TS projects use file-based modules — resolve both the default export name and the filename/path as module identifiers
- [x] Handle re-exports and barrel files (`index.ts` that re-export from subdirectories)

## Import graph tracking

- [x] **`get_community_context` coupling direction** — returned 0 coupled files for `billing-fallback.tsx` even though landing page and billing page both import it. Only tracks outgoing call edges, not incoming imports. "Who imports this component?" is the most common question in React codebases.
- [x] **`analyze_impact` should follow imports, not just calls** — `PLAN_DEFINITIONS` showed 0 impact despite 2 files importing it. In TS, the import graph IS the dependency graph. A constant changing shape breaks consumers even without function calls.
- [x] **Cross-file type dependency tracking** — if `PlanId` changes from `['starter', 'professional', 'enterprise']` to add a tier, which files break? Can't answer today because we track calls, not type references.

## Graph analysis features

- [x] **Hot path / centrality score** — `get_graph_stats` shows top connected nodes, but add a "most critical files" ranking using betweenness centrality (everything flows through them). Tells you where a bug causes the most damage.
- [x] **Dead code detection** — "show me all exported functions with zero callers." Proactively flag unused exports (e.g. `getFeatureAccess`, `canAddIntegration` were exported but never called).

## Go language support (call graph is broken)

**Root cause:** Go falls back to `GenericExtractor` which has a naive 5-line call detection that only matches nodes with a top-level `"name"` field. But Go's tree-sitter produces `call_expression` nodes where the function name is in a child node (`identifier` or `selector_expression`), so every Go call is missed. JS and Python have dedicated extractors that handle this correctly.

- [x] **Create `go_extractor.ex`** — handle the three Go call patterns:
  - Direct calls: `foo(args)` → child is `identifier` node
  - Package calls: `fmt.Println(args)` → child is `selector_expression` (package.Function)
  - Method calls: `obj.Method(args)` → child is `selector_expression`
- [x] **Extract Go imports as relationships** — `import "fmt"` creates an imports edge; `import "github.com/user/pkg"` tracks external deps
- [x] **Extract Go struct/interface contains relationships** — `func (v Value) Inspect()` → method belongs to `Value` type; `type Value struct { ... }` → struct contains fields
- [x] **Register the extractor** — `defp get_extractor(:go), do: GoExtractor`
- [x] **Handle Go-specific patterns:**
  - Receiver methods: `func (v *Value) Method()` → resolve to `Value.Method`
  - Interface satisfaction (harder, but important)
  - Package-qualified names: `runtime.FromGo` not just `FromGo`

**Impact:** This would make `find_all_callers`, `find_all_callees`, `analyze_impact`, and `get_community_context` all work for Go — currently they return empty for every query.

## Dashboard

- [x] Fix UTC timestamps — display dates in user's local timezone instead of raw UTC
- [x] Add ability to delete Qdrant collections from the dashboard UI (they accumulate over time with project switching)

## Testing / Robustness

- [ ] Improve test coverage and robustness around project switching (switching collections, ETS reload, file watcher re-wiring)
- [ ] Edge cases: switching while indexing is in progress, switching to a deleted collection, rapid successive switches

---

**Core insight:** The graph engine is solid. The gaps are: (1) TypeScript idioms (imports > calls, file-based modules, type references) vs the Elixir model it was built for, and (2) languages like Go that need dedicated extractors instead of falling through to the naive generic extractor.
