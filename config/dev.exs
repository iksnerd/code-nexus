import Config

config :elixir_nexus, ElixirNexus.Endpoint,
  http: [port: 4000],
  debug_errors: true,
  code_reloader: true,
  check_origin: false

config :logger, level: :debug
