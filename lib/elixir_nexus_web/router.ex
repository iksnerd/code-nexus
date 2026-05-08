defmodule ElixirNexus.Router do
  @moduledoc "Defines browser and API routes for the ElixirNexus application."
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {ElixirNexus.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", ElixirNexus do
    pipe_through(:browser)

    live_session :default,
      on_mount: [{ElixirNexusWeb.NavHook, :default}],
      layout: {ElixirNexus.Layouts, :live} do
      live("/", DashboardLive.Index)
      live("/search", SearchLive.Index)
      live("/graph", GraphLive.Index)
      live("/vectors", VectorsLive.Index)
    end
  end

  scope "/", ElixirNexus do
    pipe_through(:api)
    get("/metrics", MetricsController, :index)
    get("/health", HealthController, :index)
  end

  scope "/api", ElixirNexus.API do
    pipe_through(:api)
    post("/search", SearchController, :search)
    post("/callees", SearchController, :callees)
    post("/index", SearchController, :index)

    get("/vectors/info", VectorsController, :info)
    get("/vectors/count", VectorsController, :count)
    post("/vectors/scroll", VectorsController, :scroll)
    get("/vectors/:id", VectorsController, :get)
    post("/vectors/delete", VectorsController, :delete)
    post("/vectors/reset", VectorsController, :reset)
  end
end
