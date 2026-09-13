# Performance benchmarks

[← Back to the README](../README.md)

Run with `mix test --include performance` (32 tests). The numbers below come from a local run recorded in March 2026 and haven't been re-measured since. Expect them to vary by machine and by whether Ollama is warm.

| Operation | Latency | Scale |
|-----------|---------|-------|
| ETS insert 10K chunks | 4ms | |
| ETS search 10K chunks | 13ms | |
| ETS 100 concurrent searches (p99) | 53ms | 10K chunks |
| Graph rebuild | 458ms | 1K chunks |
| Ollama single embed | 29ms | 768-dim |
| TF-IDF single embed | 0.09ms | 768-dim (~456x faster) |
| Hybrid search e2e (p50) | 21ms | |
| analyze_impact | 3.5ms | 500 entities |
| get_community_context | 1.2ms | 500 entities |
| Index 20 files (Broadway) | 2.0s | |
| PubSub 100 subscribers | 0.17ms max | |
