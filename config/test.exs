import Config

# Suppress logging during tests
config :logger, level: :warning

# Test-specific configuration
config :elixir_nexus, env: :test

# Fast-fail Ollama in tests — no real model is available, retries just slow CI down.
# Production still uses the longer 60s timeout + 3 retries from EmbeddingModel.
config :elixir_nexus,
  ollama_timeout: 1_000,
  ollama_retry_attempts: 1,
  ollama_retry_backoff_ms: 0
