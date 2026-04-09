import Config

# Ollama URL can be overridden at runtime (e.g. host.docker.internal in Docker)
if ollama_url = System.get_env("OLLAMA_URL") do
  config :elixir_nexus, ollama_url: ollama_url
end
