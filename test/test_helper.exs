ExUnit.start(exclude: [:performance])

# Configure test environment
Application.put_env(:elixir_nexus, :env, :test)

# Load Mox definitions
Code.require_file("support/mox_setup.ex", __DIR__)
