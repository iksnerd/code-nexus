import Config

config :elixir_nexus, ElixirNexus.Endpoint,
  http: [port: 4100, protocol_options: [max_header_value_length: 32_768]],
  debug_errors: true,
  code_reloader: true,
  check_origin: false

config :logger, level: :debug
