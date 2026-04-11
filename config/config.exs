import Config

config :elixir_nexus,
  ecto_repos: []

config :elixir_nexus, ElixirNexus.Endpoint,
  url: [host: "localhost"],
  http: [port: 4100, transport_options: [socket_opts: []]],
  render_errors: [
    formats: [html: ElixirNexus.ErrorHTML, json: ElixirNexus.ErrorJSON],
    layout: false
  ],
  pubsub_server: ElixirNexus.PubSub,
  live_view: [signing_salt: "ElixirNexus/1.0"],
  secret_key_base: System.get_env("SECRET_KEY_BASE", "dev_only_placeholder_not_a_secret_do_not_use_in_production_x_x_x")

config :logger,
  level: :info

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :file, :line]

# Embedding model config (Ollama nomic-embed-text, 768-dim)
config :elixir_nexus,
  ollama_url: "http://localhost:11434"

# Qdrant config
config :elixir_nexus, :qdrant,
  url: "http://localhost:6333",
  collection: "codebase_index",
  vector_size: 768

if Mix.env() == :dev do
  config :elixir_nexus, ElixirNexus.Endpoint,
    debug_errors: true,
    code_reloader: true,
    check_origin: false,
    watchers: []
end

if Mix.env() == :prod do
  config :elixir_nexus, ElixirNexus.Endpoint,
    url: [scheme: "https", host: System.get_env("DOMAIN"), port: 443],
    http: [
      port: String.to_integer(System.get_env("PORT") || "4100"),
      transport_options: [socket_opts: []]
    ],
    cache_static_manifest: "priv/static/cache_manifest.json"
end
