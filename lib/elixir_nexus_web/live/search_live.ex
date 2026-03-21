defmodule ElixirNexus.SearchLive.Index do
  @moduledoc false
  use Phoenix.LiveView
  import ElixirNexusWeb.CoreComponents

  def render(assigns) do
    ~H"""
    <h2 class="text-2xl font-bold text-white mb-6">Code Search</h2>

    <!-- Search Form -->
    <form phx-submit="search" phx-change="search_changed" class="mb-8">
      <div class="flex gap-4">
        <div class="relative flex-1">
          <input
            type="text"
            name="query"
            value={@query}
            placeholder="Search code by function name, logic, or concept..."
            class="w-full px-4 py-3 bg-slate-800 border border-slate-700 rounded-lg text-white placeholder-slate-500 focus:outline-none focus:border-blue-500 pr-20"
            autocomplete="off"
            phx-debounce="300"
            phx-hook="SearchFocus"
            id="search-input"
          />
          <kbd class="absolute right-3 top-1/2 -translate-y-1/2 text-xs text-slate-500 bg-slate-700 px-2 py-0.5 rounded border border-slate-600">
            Cmd+K
          </kbd>
        </div>
        <button
          type="submit"
          class="px-6 py-3 bg-blue-600 hover:bg-blue-700 text-white font-semibold rounded-lg transition"
          disabled={@loading}
        >
          <%= if @loading, do: "Searching...", else: "Search" %>
        </button>
      </div>
    </form>

    <!-- Results -->
    <%= if @results != [] do %>
      <div class="space-y-4">
        <div class="flex items-center justify-between mb-4">
          <h3 class="text-lg font-semibold text-slate-300">
            <%= length(@results) %> results for '<span class="text-blue-400"><%= @query %></span>'
          </h3>
          <%= if @search_time_ms do %>
            <span class="text-sm text-slate-500"><%= @search_time_ms %> ms</span>
          <% end %>
        </div>
        <%= for result <- @results do %>
          <div class="bg-slate-800/50 border border-slate-700/50 rounded-lg p-6 hover:border-slate-600 transition">
            <div class="flex items-start justify-between mb-3">
              <div>
                <div class="flex items-center gap-2 mb-1">
                  <h4 class="text-lg font-bold text-blue-400"><%= result.entity["name"] %></h4>
                  <.entity_badge type={result.entity["entity_type"] || "unknown"} />
                  <%= if result.entity["language"] do %>
                    <.language_badge language={result.entity["language"]} />
                  <% end %>
                  <%= if result.entity["visibility"] do %>
                    <span class="text-xs text-slate-500"><%= result.entity["visibility"] %></span>
                  <% end %>
                </div>
                <p class="text-sm text-slate-400"><%= result.entity["file_path"] %></p>
              </div>
              <div class="text-right">
                <p class="text-sm text-slate-400">
                  Score: <span class="text-emerald-400 font-semibold"><%= Float.round(result.score, 3) %></span>
                </p>
              </div>
            </div>

            <div class="bg-slate-900/50 rounded border border-slate-700/30 p-3 mb-3 max-h-40 overflow-y-auto">
              <pre class="text-slate-300 text-xs font-mono whitespace-pre-wrap break-words"><%= String.slice(result.entity["content"] || "", 0..200) %><%= if String.length(result.entity["content"] || "") > 200, do: "...", else: "" %></pre>
            </div>

            <div class="flex flex-wrap gap-2">
              <span class="text-xs bg-slate-700 text-slate-300 px-2 py-1 rounded">
                Lines <%= result.entity["start_line"] %>-<%= result.entity["end_line"] %>
              </span>
              <%= if result.entity["references"] && length(result.entity["references"]) > 0 do %>
                <span class="text-xs bg-blue-900/50 text-blue-300 px-2 py-1 rounded">
                  <%= length(result.entity["references"]) %> references
                </span>
              <% end %>
              <%= if length(result.entity["calls"] || []) > 0 do %>
                <span class="text-xs bg-violet-900/40 text-violet-300 px-2 py-1 rounded">
                  <%= length(result.entity["calls"]) %> calls
                </span>
              <% end %>
              <%= if length(result.entity["is_a"] || []) > 0 do %>
                <span class="text-xs bg-amber-900/40 text-amber-300 px-2 py-1 rounded">
                  <%= length(result.entity["is_a"]) %> imports
                </span>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    <% else %>
      <%= if @searched do %>
        <div class="text-center py-12">
          <p class="text-slate-400 text-lg">No results found for '<span class="text-blue-400"><%= @query %></span>'</p>
        </div>
      <% else %>
        <div class="text-center py-12">
          <p class="text-slate-400 text-lg">Enter a query to search</p>
        </div>
      <% end %>
    <% end %>
    """
  end

  def mount(_params, _session, socket) do
    if connected?(socket) do
      ElixirNexus.Events.subscribe_indexing()
    end

    {:ok,
     assign(socket,
       current_path: "/search",
       results: [],
       loading: false,
       searched: false,
       query: "",
       search_time_ms: nil
     )}
  end

  def handle_params(params, uri, socket) do
    socket = assign(socket, current_path: URI.parse(uri).path)

    case params do
      %{"query" => query} when query != "" ->
        {:noreply, run_search(socket, query)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("switch_collection", %{"collection" => name}, socket) do
    ElixirNexus.ProjectSwitcher.switch_project(name)
    {:noreply, socket}
  end

  def handle_event("search", %{"query" => query}, socket) when query != "" do
    {:noreply, push_patch(socket, to: "/search?query=#{URI.encode_www_form(query)}")}
  end

  def handle_event("search", _params, socket), do: {:noreply, socket}

  def handle_event("search_changed", %{"query" => query}, socket) when byte_size(query) >= 3 do
    {:noreply, run_search(socket, query)}
  end

  def handle_event("search_changed", _params, socket), do: {:noreply, socket}

  def handle_info({:indexing_complete, _data}, socket) do
    {:noreply, put_flash(socket, :info, "Index updated")}
  end

  def handle_info({:file_reindexed, _path}, socket) do
    {:noreply, put_flash(socket, :info, "Index updated")}
  end

  def handle_info({:collection_changed, _name}, socket) do
    {:noreply, assign(socket, results: [], searched: false, query: "")}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp run_search(socket, query) do
    start = System.monotonic_time(:millisecond)
    socket = assign(socket, loading: true, searched: true, query: query)

    {:ok, results} = ElixirNexus.Search.search_code(query, 10)
    elapsed = System.monotonic_time(:millisecond) - start
    assign(socket, results: results, loading: false, search_time_ms: elapsed)
  end
end
