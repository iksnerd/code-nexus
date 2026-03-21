# Dashboard UI Architecture

The ElixirNexus web dashboard is a Phoenix LiveView application at `http://localhost:4100`.

## Current Implementation

### Three LiveView Pages

1. **DashboardLive** — System overview
   - Indexing statistics (file count, entity count, chunk count)
   - System health (Qdrant connection, Bumblebee status, file watcher)
   - Entity type breakdown and language distribution
   - Call/import/contains edge counts and top connected modules
   - Activity feed (indexing progress, completion, file reindex events)
   - Multi-project dropdown (switches Qdrant collection via ProjectSwitcher)
   - **Auto-sync from Qdrant**: detects when external indexing (MCP) changes point count and reloads ETS

2. **SearchLive** — Interactive hybrid search
   - Search input with live results (debounced, URL-synced)
   - Scored results with entity type badges (function, class, method, module)
   - Language badges and visibility indicators
   - Call graph tags (calls, is_a, contains relationships)
   - Search timing display

3. **VectorLive** — Vector management
   - Browse stored vectors with pagination (Qdrant scroll)
   - Filter by entity type
   - Inspect individual point payloads
   - Delete points, reset collections
   - Re-index codebase button
   - Collection metadata and point counts

## Data Flow

| Layer | Responsibility |
| --- | --- |
| **Qdrant** | Source of truth for vectors and entity payloads |
| **ChunkCache (ETS)** | Local cache — auto-synced from Qdrant on divergence |
| **GraphCache (ETS)** | Call graph nodes — rebuilt from ChunkCache |
| **Search module** | Hybrid search (RRF) + graph re-ranking |
| **LiveView** | Server-rendered HTML, pushed via WebSocket |
| **PubSub** | Intra-BEAM live updates (indexing events) |

## Cross-BEAM Sync

**Docker mode (recommended):** MCP HTTP and Phoenix run in a single BEAM instance. They share ETS, PubSub, and Qdrant — no sync delay. PubSub broadcasts `:indexing_progress`, `:indexing_complete`, `:file_reindexed` and DashboardLive receives these instantly.

**Local mode (separate BEAMs):** When running `mix mcp` (stdio) alongside `mix phx.server`, they are separate BEAM instances sharing only Qdrant, not ETS or PubSub. The dashboard auto-syncs via polling:

1. Every 3 seconds, the dashboard tick compares Qdrant point count vs local ETS count
2. If they differ by more than 5, it triggers `ProjectSwitcher.reload_from_qdrant/0`
3. This clears ETS, scrolls all points from Qdrant, and rebuilds ChunkCache + GraphCache
4. All dashboard stats (files, chunks, nodes, edges, languages, top connected) update automatically

## Multi-project Support

- Dashboard dropdown lists all Qdrant collections (`nexus_<name>`)
- Switching collections triggers `ProjectSwitcher.switch_project/1`:
  1. Switches active Qdrant collection
  2. Clears ETS caches
  3. Scrolls all points from new collection into ETS
  4. Rebuilds GraphCache from chunks
  5. Broadcasts `:collection_changed` via PubSub

## Future Ideas

- **Graph visualization**: vis-network or D3.js for call graph rendering via LiveView hooks
- **Code preview overlays**: hover to see function definitions inline
- **Impact radius view**: visual blast radius from `analyze_impact` results
- **Chunk boundary view**: show exactly what text gets embedded per chunk
