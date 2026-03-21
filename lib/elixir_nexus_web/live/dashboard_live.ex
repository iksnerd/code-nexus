defmodule ElixirNexus.DashboardLive.Index do
  use Phoenix.LiveView
  import ElixirNexusWeb.CoreComponents
  require Logger

  @tick_interval 3000
  @max_activity 30

  def render(assigns) do
    ~H"""
    <!-- System Status Bar -->
    <div class="flex flex-wrap items-center gap-3 mb-6">
      <div class="flex items-center gap-2 bg-slate-800/50 border border-slate-700/50 rounded-lg px-3 py-2">
        <span class="text-slate-400 text-xs">Qdrant</span>
        <.status_indicator status={@qdrant_health} />
      </div>
      <div class="flex items-center gap-2 bg-slate-800/50 border border-slate-700/50 rounded-lg px-3 py-2">
        <span class="text-slate-400 text-xs">Embeddings</span>
        <span class={"text-xs font-medium px-2 py-0.5 rounded #{if @bumblebee_available, do: "bg-emerald-900/50 text-emerald-300", else: "bg-amber-900/50 text-amber-300"}"}>
          <%= if @bumblebee_available, do: "Bumblebee", else: "TF-IDF" %>
        </span>
      </div>
      <div class="flex items-center gap-2 bg-slate-800/50 border border-slate-700/50 rounded-lg px-3 py-2">
        <span class="text-slate-400 text-xs">Watcher</span>
        <span class="text-xs text-slate-300"><%= @watcher_watching %> dirs</span>
        <%= if @watcher_pending > 0 do %>
          <span class="text-xs text-amber-400">(<%= @watcher_pending %> pending)</span>
        <% end %>
      </div>
      <div class="flex items-center gap-2 bg-slate-800/50 border border-slate-700/50 rounded-lg px-3 py-2">
        <span class="text-slate-400 text-xs">Indexer</span>
        <.status_indicator status={@indexer_status} />
      </div>
    </div>

    <!-- Primary Stats -->
    <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-8">
      <.stat_card label="Indexed Files" value={@indexed_files} color="blue" animated />
      <.stat_card label="Total Chunks" value={@total_chunks} color="emerald" animated />
      <.stat_card label="Graph Nodes" value={@graph_node_count} color="violet" animated />
      <.stat_card label="Vocabulary" value={@vocab_size} color="amber" subtitle="unique words" animated />
    </div>

    <!-- Entity Breakdown + Language Distribution -->
    <div class="grid grid-cols-1 md:grid-cols-2 gap-6 mb-8">
      <!-- Entity Type Counts -->
      <div class="bg-slate-800/30 border border-slate-700/50 rounded-xl p-5">
        <h3 class="text-sm font-semibold text-slate-300 mb-4">Entity Types</h3>
        <div class="space-y-3">
          <%= for {type, count} <- @entity_breakdown do %>
            <div class="flex items-center gap-3">
              <.entity_badge type={type} />
              <div class="flex-1">
                <div class="bg-slate-700/50 rounded-full h-2 overflow-hidden">
                  <div
                    class={"h-full rounded-full #{bar_color(type)}"}
                    style={"width: #{bar_width(count, @graph_node_count)}%"}
                  ></div>
                </div>
              </div>
              <span class="text-slate-400 text-xs font-mono w-10 text-right"><%= count %></span>
            </div>
          <% end %>
        </div>
      </div>

      <!-- Language Distribution -->
      <div class="bg-slate-800/30 border border-slate-700/50 rounded-xl p-5">
        <h3 class="text-sm font-semibold text-slate-300 mb-4">Languages</h3>
        <div class="space-y-3">
          <%= for {lang, count} <- @language_distribution do %>
            <div class="flex items-center gap-3">
              <.language_badge language={lang} />
              <div class="flex-1">
                <div class="bg-slate-700/50 rounded-full h-2 overflow-hidden">
                  <div
                    class="h-full rounded-full bg-blue-500/70"
                    style={"width: #{bar_width(count, @total_chunks)}%"}
                  ></div>
                </div>
              </div>
              <span class="text-slate-400 text-xs font-mono w-10 text-right"><%= count %></span>
            </div>
          <% end %>
        </div>
      </div>
    </div>

    <!-- Relationship Overview -->
    <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-8">
      <.stat_card label="Call Edges" value={@calls_count} color="blue" />
      <.stat_card label="Import Edges" value={@imports_count} color="violet" />
      <.stat_card label="Contains Edges" value={@contains_count} color="emerald" />
      <div class="bg-slate-800/50 border border-slate-700/50 rounded-xl p-5">
        <p class="text-slate-400 text-sm mb-2">Top Connected</p>
        <div class="space-y-1">
          <%= for {name, degree} <- Enum.take(@top_connected, 5) do %>
            <div class="flex justify-between items-center">
              <span class="text-xs text-slate-300 truncate mr-2"><%= name %></span>
              <span class="text-xs text-slate-500 font-mono"><%= degree %></span>
            </div>
          <% end %>
          <%= if @top_connected == [] do %>
            <p class="text-xs text-slate-500">No data yet</p>
          <% end %>
        </div>
      </div>
    </div>

    <div class="grid grid-cols-1 md:grid-cols-2 gap-6 mb-8">
      <!-- Live Activity Feed -->
      <div class="bg-slate-800/30 border border-slate-700/50 rounded-xl p-5">
        <h3 class="text-sm font-semibold text-slate-300 mb-3">Activity</h3>
        <div class="max-h-64 overflow-y-auto">
          <%= if @activity == [] do %>
            <p class="text-xs text-slate-500 py-4 text-center">No recent activity</p>
          <% else %>
            <%= for event <- @activity do %>
              <.activity_item event={event} />
            <% end %>
          <% end %>
        </div>
      </div>

      <!-- Error Panel -->
      <div>
        <.error_panel errors={@errors} expanded={@errors_expanded} />
        <%= if @errors == [] do %>
          <div class="bg-slate-800/30 border border-slate-700/50 rounded-xl p-5">
            <p class="text-sm text-slate-400">No errors</p>
          </div>
        <% end %>
      </div>
    </div>

    <!-- MCP Tools -->
    <h3 class="text-sm font-semibold text-slate-300 mb-3">MCP Tools</h3>
    <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-6">
      <a href="/search" class="group bg-slate-800/50 border border-slate-700/50 hover:border-blue-500/50 hover:bg-slate-800 rounded-xl p-4 transition">
        <h4 class="text-sm font-bold text-white mb-1 group-hover:text-blue-400">search_code</h4>
        <p class="text-slate-500 text-xs">Hybrid semantic + keyword search with graph re-ranking</p>
      </a>
      <div class="bg-slate-800/50 border border-slate-700/50 rounded-xl p-4">
        <h4 class="text-sm font-bold text-white mb-1">find_callees</h4>
        <p class="text-slate-500 text-xs">All functions called by a given function</p>
      </div>
      <div class="bg-slate-800/50 border border-slate-700/50 rounded-xl p-4">
        <h4 class="text-sm font-bold text-white mb-1">find_callers</h4>
        <p class="text-slate-500 text-xs">All functions that call a given function</p>
      </div>
      <div class="bg-slate-800/50 border border-slate-700/50 rounded-xl p-4">
        <h4 class="text-sm font-bold text-white mb-1">analyze_impact</h4>
        <p class="text-slate-500 text-xs">Transitive blast radius via callers-of-callers</p>
      </div>
      <div class="bg-slate-800/50 border border-slate-700/50 rounded-xl p-4">
        <h4 class="text-sm font-bold text-white mb-1">get_community_context</h4>
        <p class="text-slate-500 text-xs">Structurally coupled files via call-graph edges</p>
      </div>
      <div class="bg-slate-800/50 border border-slate-700/50 rounded-xl p-4">
        <h4 class="text-sm font-bold text-white mb-1">find_module_hierarchy</h4>
        <p class="text-slate-500 text-xs">Module parents and contained functions</p>
      </div>
      <div class="bg-slate-800/50 border border-slate-700/50 rounded-xl p-4">
        <h4 class="text-sm font-bold text-white mb-1">get_graph_stats</h4>
        <p class="text-slate-500 text-xs">Codebase overview: nodes, edges, languages</p>
      </div>
      <a href="/vectors" class="group bg-slate-800/50 border border-slate-700/50 hover:border-emerald-500/50 hover:bg-slate-800 rounded-xl p-4 transition">
        <h4 class="text-sm font-bold text-white mb-1 group-hover:text-emerald-400">reindex</h4>
        <p class="text-slate-500 text-xs">Parse and index source files for search + call graph</p>
      </a>
    </div>

    <!-- Footer -->
    <div class="border-t border-slate-700/50 pt-4 mt-4 flex items-center justify-between">
      <span class="text-xs text-slate-600">ElixirNexus v0.1.0</span>
      <span class="text-xs text-slate-600">Elixir/OTP + Bumblebee + Qdrant + Tree-sitter</span>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    if connected?(socket) do
      ElixirNexus.Events.subscribe_indexing()
      schedule_tick()
    end

    socket =
      socket
      |> assign(
        current_path: "/",
        activity: [],
        errors: [],
        errors_expanded: false
      )
      |> assign_stats()

    {:ok, socket}
  end

  def handle_params(_params, uri, socket) do
    {:noreply, assign(socket, current_path: URI.parse(uri).path)}
  end

  def handle_event("switch_collection", %{"collection" => name}, socket) do
    ElixirNexus.ProjectSwitcher.switch_project(name)
    {:noreply, socket}
  end

  def handle_event("toggle_errors", _params, socket) do
    {:noreply, assign(socket, errors_expanded: !socket.assigns.errors_expanded)}
  end

  def handle_info(:tick, socket) do
    schedule_tick()
    socket = maybe_sync_from_qdrant(socket)
    {:noreply, assign_stats(socket)}
  end

  def handle_info({:indexing_complete, data}, socket) do
    socket =
      socket
      |> assign_stats()
      |> add_activity(:indexing_complete, "Indexing complete: #{data[:files] || 0} files, #{data[:chunks] || 0} chunks")

    {:noreply, socket}
  end

  def handle_info({:indexing_progress, %{batch_chunks: bc, batch_files: bf}}, socket) do
    socket =
      socket
      |> assign(indexer_status: "indexing")
      |> add_activity(:indexing_progress, "Batch: #{bf} files, #{bc} chunks")

    {:noreply, socket}
  end

  def handle_info({:indexing_progress, _data}, socket) do
    {:noreply, assign(socket, indexer_status: "indexing")}
  end

  def handle_info({:file_reindexed, path}, socket) do
    socket =
      socket
      |> assign_stats()
      |> add_activity(:file_reindexed, "Re-indexed: #{Path.basename(path)}")

    {:noreply, socket}
  end

  def handle_info({:collection_changed, name}, socket) do
    socket =
      socket
      |> assign(activity: [])
      |> assign_stats()
      |> add_activity(:collection_changed, "Switched to #{name}")

    {:noreply, socket}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_interval)
  end

  defp assign_stats(socket) do
    indexer = safe_call(fn -> ElixirNexus.Indexer.status() end, %{indexed_files: 0, total_chunks: 0, status: :idle, errors: []})
    graph_nodes = safe_call(fn -> ElixirNexus.GraphCache.all_nodes() end, %{})
    vocab = safe_call(fn -> ElixirNexus.TFIDFEmbedder.vocab_size() end, 0)
    bumblebee = safe_call(fn -> ElixirNexus.EmbeddingModel.available?() end, false)
    watcher = safe_call(fn -> ElixirNexus.FileWatcher.status() end, %{watching: 0, pending: 0})

    qdrant_health =
      case safe_call(fn -> ElixirNexus.QdrantClient.health_check() end, {:error, :unknown}) do
        {:ok, _} -> "ready"
        _ -> "error"
      end

    # Entity breakdown
    entity_breakdown =
      graph_nodes
      |> Map.values()
      |> Enum.group_by(fn node -> node["type"] || node["entity_type"] || "unknown" end)
      |> Enum.map(fn {type, nodes} -> {type, length(nodes)} end)
      |> Enum.sort_by(fn {_, count} -> -count end)

    # Language distribution from chunks
    language_distribution = compute_language_distribution()

    # Relationship counts
    {calls, imports, contains} = count_relationships(graph_nodes)

    # Top connected entities
    top_connected =
      graph_nodes
      |> Map.values()
      |> Enum.map(fn node ->
        degree = (node["outgoing_degree"] || 0) + (node["incoming_count"] || 0)
        {node["name"] || "?", degree}
      end)
      |> Enum.sort_by(fn {_, d} -> -d end)
      |> Enum.take(5)

    indexer_status =
      case indexer.status do
        :indexing -> "indexing"
        :idle -> "ready"
        _ -> "ready"
      end

    # Derive indexed file count from ChunkCache (survives process restarts, shared via ETS)
    # Falls back to Indexer's in-memory count if cache is empty
    cached_file_count =
      try do
        ElixirNexus.ChunkCache.all()
        |> Enum.map(& &1.file_path)
        |> Enum.uniq()
        |> length()
      rescue
        _ -> 0
      end

    indexed_files = if cached_file_count > 0, do: cached_file_count, else: indexer.indexed_files
    total_chunks = if ElixirNexus.ChunkCache.count() > 0, do: ElixirNexus.ChunkCache.count(), else: indexer.total_chunks

    assign(socket,
      indexed_files: indexed_files,
      total_chunks: total_chunks,
      indexer_status: indexer_status,
      errors: indexer.errors,
      graph_node_count: map_size(graph_nodes),
      vocab_size: vocab,
      bumblebee_available: bumblebee,
      watcher_watching: watcher.watching,
      watcher_pending: watcher.pending,
      qdrant_health: qdrant_health,
      entity_breakdown: entity_breakdown,
      language_distribution: language_distribution,
      calls_count: calls,
      imports_count: imports,
      contains_count: contains,
      top_connected: top_connected
    )
  end

  defp compute_language_distribution do
    try do
      ElixirNexus.ChunkCache.all()
      |> Enum.group_by(fn chunk -> to_string(chunk[:language] || chunk.language || "unknown") end)
      |> Enum.map(fn {lang, chunks} -> {lang, length(chunks)} end)
      |> Enum.sort_by(fn {_, count} -> -count end)
    rescue
      e ->
        Logger.warning("Failed to compute language distribution: #{inspect(e)}")
        []
    end
  end

  defp count_relationships(graph_nodes) do
    Enum.reduce(Map.values(graph_nodes), {0, 0, 0}, fn node, {calls, imports, contains} ->
      {
        calls + length(node["calls"] || []),
        imports + length(node["is_a"] || []),
        contains + length(node["contains"] || [])
      }
    end)
  end

  defp add_activity(socket, type, message) do
    event = %{
      type: type,
      message: message,
      time: Calendar.strftime(DateTime.utc_now(), "%H:%M:%S")
    }

    activity = [event | socket.assigns.activity] |> Enum.take(@max_activity)
    assign(socket, activity: activity)
  end

  # Detect when Qdrant has been updated externally (e.g. by MCP in a separate BEAM)
  # and reload local ETS caches to stay in sync.
  defp maybe_sync_from_qdrant(socket) do
    qdrant_count = safe_call(fn ->
      case ElixirNexus.QdrantClient.count_points() do
        {:ok, %{"result" => %{"count" => count}}} -> count
        _ -> nil
      end
    end, nil)

    ets_count = safe_call(fn -> ElixirNexus.ChunkCache.count() end, 0)

    if qdrant_count && qdrant_count != ets_count && abs(qdrant_count - ets_count) > 5 do
      Logger.info("Dashboard: Qdrant has #{qdrant_count} points but ETS has #{ets_count}, syncing...")
      safe_call(fn -> ElixirNexus.ProjectSwitcher.reload_from_qdrant() end, :ok)
      add_activity(socket, :synced, "Synced from Qdrant: #{qdrant_count} chunks loaded")
    else
      socket
    end
  end

  defp safe_call(fun, default) do
    try do
      fun.()
    rescue
      e ->
        Logger.debug("Dashboard safe_call failed: #{inspect(e)}")
        default
    catch
      :exit, reason ->
        Logger.debug("Dashboard safe_call exit: #{inspect(reason)}")
        default
    end
  end

  defp bar_width(_count, 0), do: 0
  defp bar_width(count, total), do: min(round(count / total * 100), 100)

  defp bar_color("module"), do: "bg-purple-500/70"
  defp bar_color("function"), do: "bg-sky-500/70"
  defp bar_color("macro"), do: "bg-amber-500/70"
  defp bar_color("struct"), do: "bg-emerald-500/70"
  defp bar_color(_), do: "bg-slate-500/70"
end
