# REST API

[← Back to the README](../README.md)

The Phoenix app on port `4100` serves these endpoints alongside the dashboard. Routes are defined in `lib/elixir_nexus_web/router.ex`.

## Observability

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/metrics` | Prometheus metrics (text format 0.0.4): search latency, indexing throughput, Qdrant ops, BEAM VM stats |
| GET | `/health` | Readiness for MCP, Qdrant, Ollama, and indexed projects. HTTP 200 when all dependencies are healthy, 503 otherwise |

## Search and discovery

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/search` | Hybrid semantic + keyword search |
| POST | `/api/callees` | Find callees of a function |
| POST | `/api/index` | Trigger indexing |

## Vector management

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/vectors/info` | Collection metadata |
| GET | `/api/vectors/count` | Point count |
| POST | `/api/vectors/scroll` | Paginated point listing |
| GET | `/api/vectors/:id` | Get a single point |
| POST | `/api/vectors/delete` | Delete points by ID |
| POST | `/api/vectors/reset` | Reset the collection |
