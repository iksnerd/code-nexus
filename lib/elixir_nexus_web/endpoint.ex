defmodule ElixirNexus.Endpoint do
  use Phoenix.Endpoint, otp_app: :elixir_nexus

  @session_options [
    store: :cookie,
    key: "_elixir_nexus_key",
    signing_salt: "ElixirNexus"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  plug Plug.Static,
    at: "/",
    from: :elixir_nexus,
    gzip: false,
    only: ~w(css fonts images js favicon.ico robots.txt)

  # Code reloading can be explicitly enabled under the :code_reloader
  # configuration of your endpoint.
  if Mix.env() == :dev do
    plug Phoenix.CodeReloader
  end

  plug Plug.Logger
  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session,
    store: :cookie,
    key: "_elixir_nexus_key",
    signing_salt: "ElixirNexus"

  plug ElixirNexus.Router
end
