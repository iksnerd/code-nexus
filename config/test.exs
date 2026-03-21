import Config

# Suppress logging during tests
config :logger, level: :warning

# Test-specific configuration
config :elixir_nexus, env: :test
