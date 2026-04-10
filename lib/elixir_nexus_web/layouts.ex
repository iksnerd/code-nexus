defmodule ElixirNexus.Layouts do
  use Phoenix.Component
  import ElixirNexusWeb.CoreComponents

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="UTF-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title><%= assigns[:page_title] || "CodeNexus" %></title>
        <link rel="icon" type="image/svg+xml" href="/images/favicon.svg" />
        <script src="https://cdn.tailwindcss.com"></script>
        <script src="https://d3js.org/d3.v7.min.js"></script>
        <script src="/js/phoenix.min.js"></script>
        <script src="/js/phoenix_live_view.min.js"></script>
        <script defer src="/js/app.js"></script>
        <style>
          @keyframes pulse-dot {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.4; }
          }
          .animate-pulse-dot { animation: pulse-dot 1.5s ease-in-out infinite; }
          @keyframes fade-in-up {
            from { opacity: 0; transform: translateY(8px); }
            to { opacity: 1; transform: translateY(0); }
          }
          .animate-fade-in { animation: fade-in-up 0.3s ease-out; }
        </style>
      </head>
      <body class="bg-slate-950 text-slate-100">
        <%= @inner_content %>
      </body>
    </html>
    """
  end

  def live(assigns) do
    ~H"""
    <div class="min-h-screen bg-gradient-to-br from-slate-950 via-slate-900 to-slate-950">
      <header class="border-b border-slate-700/50 bg-slate-900/50 backdrop-blur-sm sticky top-0 z-50">
        <div class="max-w-7xl mx-auto px-6 py-3 flex justify-between items-center">
          <div class="flex items-center gap-4">
            <a href="/" class="flex items-center gap-2 text-xl font-bold text-white tracking-tight">
              <img src="/images/logo.svg" alt="CodeNexus" class="h-7 w-7" />
              CodeNexus
            </a>
            <form phx-change="switch_collection" class="flex items-center">
              <select
                name="collection"
                class="bg-slate-800 border border-slate-600 text-slate-200 rounded-lg px-3 py-1.5 text-xs font-mono focus:border-blue-500 focus:outline-none"
              >
                <%= for c <- @collections do %>
                  <option value={c} selected={c == @active_collection}><%= c %></option>
                <% end %>
              </select>
            </form>
          </div>
          <nav class="flex items-center gap-6">
            <a
              href="/"
              class={"text-sm font-medium transition #{if @current_path == "/", do: "text-white", else: "text-slate-400 hover:text-white"}"}
            >
              Dashboard
            </a>
            <a
              href="/search"
              class={"text-sm font-medium transition #{if @current_path == "/search", do: "text-white", else: "text-slate-400 hover:text-white"}"}
            >
              Search
            </a>
            <a
              href="/graph"
              class={"text-sm font-medium transition #{if @current_path == "/graph", do: "text-white", else: "text-slate-400 hover:text-white"}"}
            >
              Graph
            </a>
            <a
              href="/vectors"
              class={"text-sm font-medium transition #{if @current_path == "/vectors", do: "text-white", else: "text-slate-400 hover:text-white"}"}
            >
              Vectors
            </a>
            <%= if assigns[:indexer_status] do %>
              <.status_indicator status={assigns[:indexer_status] || "ready"} />
            <% end %>
          </nav>
        </div>
      </header>
      <main class="max-w-7xl mx-auto px-6 py-8 animate-fade-in" phx-hook="FadeIn" id="main-content">
        <%= @inner_content %>
      </main>
    </div>
    """
  end
end
