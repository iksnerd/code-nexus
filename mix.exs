defmodule ElixirNexus.MixProject do
  use Mix.Project

  def project do
    [
      app: :elixir_nexus,
      version: "0.7.0",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ElixirNexus.Application, []}
    ]
  end

  def cli do
    [preferred_envs: [coveralls: :test, "coveralls.detail": :test, "coveralls.html": :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Web framework
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 0.20"},
      {:plug_cowboy, "~> 2.6"},

      # Vector DB client (using HTTP directly via HTTPoison)

      # Code parsing
      {:sourceror, "~> 1.4"},
      {:rustler, "~> 0.37", optional: true},

      # HTTP client
      {:httpoison, "~> 2.0"},
      {:jason, "~> 1.4"},

      # Utilities
      {:gen_stage, "~> 1.2"},
      {:broadway, "~> 1.0"},
      {:file_system, "~> 0.2"},

      # MCP protocol
      {:ex_mcp, "~> 0.9.0"},

      # Dev/Test
      {:mix_test_watch, "~> 1.1", only: :dev},
      {:ex_doc, "~> 0.31", only: :dev},
      {:floki, ">= 0.30.0", only: :test},
      {:mox, "~> 1.1", only: :test},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end
end
