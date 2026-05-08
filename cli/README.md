# nexus CLI

Standalone terminal client for [CodeNexus](https://github.com/iksnerd/code-nexus) — the graph-powered code intelligence MCP server.

No Elixir or BEAM required. The CLI makes HTTP calls to a running CodeNexus server.

## Install

Download the binary for your platform from the [latest GitHub Release](https://github.com/iksnerd/code-nexus/releases/latest):

**macOS (Apple Silicon)**
```bash
curl -L https://github.com/iksnerd/code-nexus/releases/latest/download/nexus_darwin_arm64.tar.gz | tar xz
sudo mv nexus /usr/local/bin/
```

**macOS (Intel)**
```bash
curl -L https://github.com/iksnerd/code-nexus/releases/latest/download/nexus_darwin_amd64.tar.gz | tar xz
sudo mv nexus /usr/local/bin/
```

**Linux (amd64)**
```bash
curl -L https://github.com/iksnerd/code-nexus/releases/latest/download/nexus_linux_amd64.tar.gz | tar xz
sudo mv nexus /usr/local/bin/
```

**Build from source** (requires Go 1.21+):
```bash
cd cli && make build
sudo mv nexus /usr/local/bin/
```

## Prerequisites

A running CodeNexus server. Start one with Docker:

```bash
WORKSPACE=~/projects docker-compose up -d
```

The CLI defaults to `http://localhost:3002`. Override with `--server` or `NEXUS_URL`.

## Usage

```
nexus [command] [flags]
```

Run `nexus` with no arguments for an interactive command picker.

### Commands

| Command | Description |
|---|---|
| `nexus search <query>` | Hybrid semantic + keyword search |
| `nexus callers <entity>` | Find all callers of a function |
| `nexus callees <entity>` | Find all functions called by an entity |
| `nexus impact <entity>` | Transitive blast radius of a change |
| `nexus dead-code` | Exported functions with no callers |
| `nexus stats` | Call graph statistics |
| `nexus hierarchy <entity>` | Module hierarchy for an entity |
| `nexus status` | Server status and project info |
| `nexus reindex [path]` | Index or re-index a project |

### Global flags

| Flag | Default | Description |
|---|---|---|
| `--server` | `http://localhost:3002` | CodeNexus server URL |
| `--json` | false | Output raw JSON |

`NEXUS_URL` env var overrides the `--server` default.

### Examples

```bash
# Search across indexed code
nexus search "qdrant hybrid search"
nexus search "error handling in HTTP client" --limit 20

# Call graph traversal
nexus callers embed_and_store
nexus callees "ElixirNexus.Indexer" --limit 5

# Impact analysis — what breaks if this changes?
nexus impact QdrantClient.hybrid_search --depth 5

# Dead code — unreachable public functions
nexus dead-code
nexus dead-code --prefix /workspace/myproject/lib

# Graph stats and server info
nexus stats
nexus status

# Index a project
nexus reindex
nexus reindex ~/projects/myapp
nexus reindex control-stack   # bare name resolves via WORKSPACE

# Raw JSON output (pipe-friendly)
nexus search "indexing pipeline" --json | jq '.[0].entity.name'

# Point at a remote server
NEXUS_URL=http://myserver:3002 nexus status
nexus --server http://myserver:3002 search "query"
```

## Building

```bash
cd cli
make build    # stamps version from git tag
make install  # installs to $GOPATH/bin
```

The version shown in the CLI header (`v1.8.0`) is stamped at build time from the nearest git tag via `-ldflags`.
