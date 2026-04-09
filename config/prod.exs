import Config

config :elixir_nexus, ElixirNexus.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  secret_key_base:
    System.get_env("SECRET_KEY_BASE") ||
      raise("SECRET_KEY_BASE environment variable is required in production"),
  live_view: [
    signing_salt:
      System.get_env("LIVE_VIEW_SIGNING_SALT") ||
        raise("LIVE_VIEW_SIGNING_SALT environment variable is required in production")
  ]

config :logger, level: :info
