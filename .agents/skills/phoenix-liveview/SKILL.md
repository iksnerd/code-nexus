---
name: phoenix-liveview
description: Phoenix LiveView patterns for real-time server-rendered UIs. Use when building LiveView components, handling events, managing URL state with handle_params, subscribing to PubSub in LiveView, using push_event for JavaScript interop, or implementing lifecycle hooks with on_mount and attach_hook.
metadata:
  source: hexdocs.pm/phoenix_live_view + ElixirNexus dashboard
  docs: https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html
---

# Phoenix LiveView

## Lifecycle Callbacks

| Callback | When called | Use for |
|---|---|---|
| `mount/3` | Server render + client connect | Initial state, PubSub subscribe |
| `handle_params/3` | URL changes (including initial) | URL-driven state |
| `handle_event/3` | User interactions | Form submits, button clicks |
| `handle_info/2` | Messages from other processes | PubSub events, timers |
| `render/1` | After any state change | HEEx template |

## Basic LiveView

```elixir
defmodule MyAppWeb.SearchLive do
  use MyAppWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Only subscribe on client connection, not server pre-render
      MyApp.Events.subscribe_indexing()
    end

    {:ok, assign(socket, results: [], query: "", loading: false)}
  end

  @impl true
  def handle_params(%{"q" => query}, _uri, socket) do
    # Runs on initial load and when URL changes
    {:noreply, assign(socket, query: query)}
  end
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    results = MyApp.Search.search(query)
    {:noreply, assign(socket, results: results, query: query)}
  end

  @impl true
  def handle_info(:indexing_complete, socket) do
    # Received via PubSub
    {:noreply, assign(socket, loading: false)}
  end
end
```

## connected? — Avoid Double Work

```elixir
def mount(_params, _session, socket) do
  if connected?(socket) do
    # Run only after WebSocket connection established
    # Initial server render skips this
    Phoenix.PubSub.subscribe(MyApp.PubSub, "events")
    :timer.send_interval(3000, self(), :tick)
  end

  {:ok, socket}
end
```

## URL State with handle_params

```elixir
# Navigate to URL with params (triggers handle_params)
{:noreply, push_patch(socket, to: ~p"/search?q=#{query}")}

# In router: use live_patch-compatible routes
live "/search", SearchLive.Index, :index
```

## Periodic Updates

```elixir
def mount(_params, _session, socket) do
  if connected?(socket) do
    :timer.send_interval(3000, self(), :tick)
  end
  {:ok, socket}
end

def handle_info(:tick, socket) do
  status = MyApp.get_status()
  {:noreply, assign(socket, status: status)}
end
```

## JavaScript Interop with push_event

Send data to a JavaScript hook:

```elixir
# Server → client
def handle_info(:load_graph, socket) do
  graph_data = build_d3_graph()
  {:noreply, push_event(socket, "graph_data", graph_data)}
end
```

```javascript
// app.js hook
Hooks.GraphView = {
  mounted() {
    this.handleEvent("graph_data", ({nodes, links}) => {
      renderD3Graph(this.el, nodes, links);
    });
  }
};
```

## Async Operations

```elixir
# assign_async — auto-manages loading/result/error states
def mount(_params, _session, socket) do
  {:ok, assign_async(socket, :user, fn ->
    {:ok, %{user: fetch_user()}}
  end)}
end

# In template
<.async_result :let={user} assign={@user}>
  <:loading>Loading...</:loading>
  <:failed :let={reason}>Error: <%= reason %></:failed>
  <%= user.name %>
</.async_result>
```

## Lifecycle Hooks — Cross-View Concerns

```elixir
defmodule MyAppWeb.NavHook do
  import Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      MyApp.Events.subscribe_collection_changes()
    end

    socket = attach_hook(socket, :nav_handle_info, :handle_info, fn
      {:collection_changed, name}, socket ->
        {:halt, assign(socket, current_collection: name)}
      _other, socket ->
        {:cont, socket}
    end)

    {:cont, socket}
  end
end

# In router:
live_session :default, on_mount: MyAppWeb.NavHook do
  live "/search", SearchLive.Index
  live "/graph", GraphLive.Index
end
```

`attach_hook` lets you intercept `handle_info` (or `handle_event`, `handle_params`) before the LiveView's own handler. Return `{:halt, socket}` to stop propagation, `{:cont, socket}` to pass through.

## Template Patterns

```heex
<%!-- Conditional rendering --%>
<%= if @loading do %>
  <.spinner />
<% end %>

<%!-- List rendering --%>
<ul>
  <%= for result <- @results do %>
    <li><%= result.name %></li>
  <% end %>
</ul>

<%!-- phx-debounce for search input --%>
<input
  type="text"
  value={@query}
  phx-change="search_changed"
  phx-debounce="300"
/>

<%!-- Disabled button state --%>
<button phx-click="reindex" disabled={@reindexing}>
  <%= if @reindexing, do: "Indexing...", else: "Reindex" %>
</button>
```

## Common Mistakes

- Subscribing to PubSub without `connected?` guard causes double-subscriptions (server render + client connect)
- Using `live_redirect` when `push_patch` is sufficient — patch is faster (no remount)
- Accumulating unbounded state (activity feeds etc.) — cap with `@max_items` and slice
- Blocking `handle_info` with slow work — offload to `start_async/3` or Task
