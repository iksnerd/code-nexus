defmodule ElixirNexus do
  @moduledoc """
  ElixirNexus - A high-performance code intelligence engine built with Elixir, Ollama, and Qdrant.
  """

  @app_version Mix.Project.config()[:version]
  def version, do: @app_version
end
