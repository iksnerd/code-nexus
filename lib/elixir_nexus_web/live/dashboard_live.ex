defmodule ElixirNexus.DashboardLive.Index do
  use Phoenix.LiveView
  import ElixirNexusWeb.CoreComponents
  require Logger

  @tick_interval 3000
  @max_activity 30

  def render(assigns) do
    ~H"""
    <.status_bar {assigns} />
    <.primary_stats {assigns} />
    <.entity_language_grid {assigns} />
    <.architecture_layers {assigns} />
    <.relationship_overview {assigns} />
    <.activity_errors_section {assigns} />
    <.mcp_tools_grid {assigns} />
    <.page_footer {assigns} />
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
        errors_expanded: false,
        tick_count: 0
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
    tick = socket.assigns.tick_count + 1
    socket = assign(socket, tick_count: tick)

    case maybe_sync_from_qdrant(socket) do
      {:synced, socket} ->
        # Qdrant diverged and we reloaded — the underlying data actually changed,
        # so a full recompute is warranted.
        {:noreply, assign_stats(socket)}

      {:unchanged, socket} ->
        # Nothing changed underneath us. The heavy stats (graph nodes, chunk
        # materialization, per-node layer/relationship passes) only change on
        # indexing events, which already refresh via PubSub. Recomputing them on
        # every 3s tick pegged a core for as long as a tab stayed open, so on an
        # idle tick we only refresh the cheap live indicators.
        {:noreply, refresh_indicators(socket, tick)}
    end
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

  def handle_info({:file_deleted, path}, socket) do
    socket =
      socket
      |> assign_stats()
      |> add_activity(:file_deleted, "Deleted: #{Path.basename(path)}")

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

  # --- Render components ---

  defp status_bar(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-3 mb-6">
      <div class="flex items-center gap-2 bg-slate-800/50 border border-slate-700/50 rounded-lg px-3 py-2">
        <span class="text-slate-400 text-xs">Qdrant</span>
        <.status_indicator status={@qdrant_health} />
      </div>
      <div class="flex items-center gap-2 bg-slate-800/50 border border-slate-700/50 rounded-lg px-3 py-2">
        <span class="text-slate-400 text-xs">Embeddings</span>
        <span class={"text-xs font-medium px-2 py-0.5 rounded #{if @ollama_available, do: "bg-emerald-900/50 text-emerald-300", else: "bg-amber-900/50 text-amber-300"}"}>
          <%= if @ollama_available, do: "Ollama", else: "TF-IDF" %>
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
    """
  end

  defp primary_stats(assigns) do
    ~H"""
    <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-8">
      <.stat_card label="Indexed Files" value={@indexed_files} color="blue" animated />
      <.stat_card label="Total Chunks" value={@total_chunks} color="emerald" animated />
      <.stat_card label="Graph Nodes" value={@graph_node_count} color="violet" animated />
      <.stat_card label="Vocabulary" value={@vocab_size} color="amber" subtitle="unique words" animated />
    </div>
    """
  end

  defp entity_language_grid(assigns) do
    ~H"""
    <div class="grid grid-cols-1 md:grid-cols-2 gap-6 mb-8">
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
    """
  end

  defp architecture_layers(assigns) do
    ~H"""
    <%= if @layer_distribution != [] do %>
      <div class="bg-slate-800/30 border border-slate-700/50 rounded-xl p-5 mb-8">
        <h3 class="text-sm font-semibold text-slate-300 mb-1">Architecture Layers</h3>
        <p class="text-xs text-slate-500 mb-4">Derived from directory conventions (override in <code>.nexus.toml</code>)</p>
        <div class="space-y-3">
          <%= for {layer, count} <- @layer_distribution do %>
            <div class="flex items-center gap-3">
              <span class="text-xs font-medium text-slate-300 w-28 truncate capitalize"><%= layer %></span>
              <div class="flex-1">
                <div class="bg-slate-700/50 rounded-full h-2 overflow-hidden">
                  <div
                    class={"h-full rounded-full #{layer_color(layer)}"}
                    style={"width: #{bar_width(count, @graph_node_count)}%"}
                  ></div>
                </div>
              </div>
              <span class="text-slate-400 text-xs font-mono w-12 text-right"><%= count %></span>
            </div>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  defp relationship_overview(assigns) do
    ~H"""
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
    """
  end

  defp activity_errors_section(assigns) do
    ~H"""
    <div class="grid grid-cols-1 md:grid-cols-2 gap-6 mb-8">
      <div class="bg-slate-800/30 border border-slate-700/50 rounded-xl p-5">
        <h3 class="text-sm font-semibold text-slate-300 mb-3">Activity</h3>
        <div class="max-h-96 overflow-y-auto">
          <%= if @activity == [] do %>
            <p class="text-xs text-slate-500 py-4 text-center">No recent activity</p>
          <% else %>
            <%= for event <- @activity do %>
              <.activity_item event={event} />
            <% end %>
          <% end %>
        </div>
      </div>

      <div>
        <.error_panel errors={@errors} expanded={@errors_expanded} />
        <%= if @errors == [] do %>
          <div class="bg-slate-800/30 border border-slate-700/50 rounded-xl p-5">
            <p class="text-sm text-slate-400">No errors</p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp mcp_tools_grid(assigns) do
    ~H"""
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
        <p class="text-slate-500 text-xs">Parents and members — modules, types, TS interfaces</p>
      </div>
      <div class="bg-slate-800/50 border border-slate-700/50 rounded-xl p-4">
        <h4 class="text-sm font-bold text-white mb-1">get_graph_stats</h4>
        <p class="text-slate-500 text-xs">Overview: nodes, edges, languages, layers</p>
      </div>
      <a href="/vectors" class="group bg-slate-800/50 border border-slate-700/50 hover:border-emerald-500/50 hover:bg-slate-800 rounded-xl p-4 transition">
        <h4 class="text-sm font-bold text-white mb-1 group-hover:text-emerald-400">reindex</h4>
        <p class="text-slate-500 text-xs">Parse and index source files for search + call graph</p>
      </a>
    </div>
    """
  end

  defp page_footer(assigns) do
    ~H"""
    <div class="border-t border-slate-700/50 pt-4 mt-4 flex items-center justify-between">
      <span class="text-xs text-slate-600">CodeNexus v<%= ElixirNexus.version() %></span>
      <span class="text-xs text-slate-600">Elixir/OTP + Ollama + Qdrant + Tree-sitter</span>
    </div>
    """
  end

  # --- Private helpers ---

  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_interval)
  end

  defp assign_stats(socket) do
    indexer =
      safe_call(fn -> ElixirNexus.Indexer.status() end, %{indexed_files: 0, total_chunks: 0, status: :idle, errors: []})

    graph_nodes = safe_call(fn -> ElixirNexus.GraphCache.all_nodes() end, %{})
    vocab = safe_call(fn -> ElixirNexus.TFIDFEmbedder.vocab_size() end, 0)
    ollama = safe_call(fn -> ElixirNexus.EmbeddingModel.available?() end, false)
    watcher = safe_call(fn -> ElixirNexus.FileWatcher.status() end, %{watching: 0, pending: 0})

    qdrant_health =
      case safe_call(fn -> ElixirNexus.QdrantClient.health_check() end, {:error, :unknown}) do
        {:ok, _} -> "ready"
        _ -> "error"
      end

    entity_breakdown =
      graph_nodes
      |> Map.values()
      |> Enum.group_by(fn node -> node["entity_type"] || node["type"] || "unknown" end)
      |> Enum.map(fn {type, nodes} -> {type, length(nodes)} end)
      |> Enum.sort_by(fn {_, count} -> -count end)

    # Materialize the chunk cache once and reuse it for both the language
    # breakdown and the unique-file count — this is the heaviest read in the
    # function (full chunk payloads), so it must not be done twice.
    chunks = safe_call(fn -> ElixirNexus.ChunkCache.all() end, [])

    language_distribution = compute_language_distribution(chunks)
    layer_distribution = compute_layer_distribution(graph_nodes)

    {calls, imports, contains} = count_relationships(graph_nodes)

    top_connected =
      graph_nodes
      |> Map.values()
      |> Enum.reject(fn node ->
        name = node["name"] || ""
        String.length(name) <= 2
      end)
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

    cached_file_count =
      try do
        chunks
        |> Enum.map(& &1.file_path)
        |> Enum.uniq()
        |> length()
      rescue
        _ -> 0
      end

    chunk_count = safe_call(fn -> ElixirNexus.ChunkCache.count() end, 0)
    indexed_files = if cached_file_count > 0, do: cached_file_count, else: indexer.indexed_files
    total_chunks = if chunk_count > 0, do: chunk_count, else: indexer.total_chunks

    assign(socket,
      indexed_files: indexed_files,
      total_chunks: total_chunks,
      indexer_status: indexer_status,
      errors: indexer.errors,
      graph_node_count: map_size(graph_nodes),
      vocab_size: vocab,
      ollama_available: ollama,
      watcher_watching: watcher.watching,
      watcher_pending: watcher.pending,
      qdrant_health: qdrant_health,
      entity_breakdown: entity_breakdown,
      language_distribution: language_distribution,
      layer_distribution: layer_distribution,
      calls_count: calls,
      imports_count: imports,
      contains_count: contains,
      top_connected: top_connected
    )
  end

  defp compute_language_distribution(chunks) do
    try do
      chunks
      |> Enum.group_by(fn chunk -> to_string(chunk[:language] || chunk.language || "unknown") end)
      |> Enum.map(fn {lang, chunks} -> {lang, length(chunks)} end)
      |> Enum.sort_by(fn {_, count} -> -count end)
    rescue
      e ->
        Logger.warning("Failed to compute language distribution: #{inspect(e)}")
        []
    end
  end

  # Architectural layer breakdown — mirrors Search.GraphStats.compute_layers/1 so the
  # dashboard agrees with get_graph_stats. Classified on root-relative paths; a lone "other"
  # row (flat project, nothing to show) collapses to empty so the panel hides itself.
  defp compute_layer_distribution(graph_nodes) do
    {config_root, config} =
      safe_call(fn -> ElixirNexus.ProjectConfig.current() end, {nil, %ElixirNexus.ProjectConfig{}})

    counts =
      graph_nodes
      |> Map.values()
      |> Enum.reduce(%{}, fn node, acc ->
        path = node["file_path"] || ""
        rel = if config_root, do: Path.relative_to(path, config_root), else: path
        layer = ElixirNexus.ProjectConfig.layer_for(config, rel)
        Map.update(acc, layer, 1, &(&1 + 1))
      end)
      |> Enum.sort_by(fn {_layer, count} -> -count end)

    case counts do
      [{"other", _}] -> []
      other -> other
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
      time: format_local_time()
    }

    activity = [event | socket.assigns.activity] |> Enum.take(@max_activity)
    assign(socket, activity: activity)
  end

  defp format_local_time do
    DateTime.to_unix(DateTime.utc_now(), :millisecond)
  end

  # Detect when Qdrant has been updated externally (e.g. by MCP in a separate BEAM)
  # and reload local ETS caches to stay in sync.
  # How often (in ticks) to refresh the network-bound Ollama availability check.
  # Qdrant health piggybacks on the count_points call we already make every tick
  # for sync detection; Ollama has no such free signal, so we poll it less often
  # to avoid an extra HTTP round-trip on every 3s idle tick.
  @ollama_poll_every 5

  # Cheap per-tick refresh: live status indicators that can change without an
  # indexing PubSub event. Deliberately avoids the full-graph / full-chunk
  # recomputation in assign_stats/1 — see handle_info(:tick). Qdrant health is set
  # by maybe_sync_from_qdrant/1; indexer + watcher status are cheap local reads.
  defp refresh_indicators(socket, tick) do
    indexer = safe_call(fn -> ElixirNexus.Indexer.status() end, %{status: :idle, errors: []})
    watcher = safe_call(fn -> ElixirNexus.FileWatcher.status() end, %{watching: 0, pending: 0})

    indexer_status =
      case indexer.status do
        :indexing -> "indexing"
        _ -> "ready"
      end

    socket =
      assign(socket,
        indexer_status: indexer_status,
        errors: indexer.errors,
        watcher_watching: watcher.watching,
        watcher_pending: watcher.pending
      )

    if rem(tick, @ollama_poll_every) == 0 do
      assign(socket, ollama_available: safe_call(fn -> ElixirNexus.EmbeddingModel.available?() end, false))
    else
      socket
    end
  end

  defp maybe_sync_from_qdrant(socket) do
    qdrant_count =
      safe_call(
        fn ->
          case ElixirNexus.QdrantClient.count_points() do
            {:ok, %{"result" => %{"count" => count}}} -> count
            _ -> nil
          end
        end,
        nil
      )

    # Reuse the count_points result as the Qdrant liveness signal — a successful
    # count means Qdrant is reachable, so we avoid a separate health_check call.
    socket = assign(socket, qdrant_health: if(qdrant_count, do: "ready", else: "error"))

    ets_count = safe_call(fn -> ElixirNexus.ChunkCache.count() end, 0)

    if qdrant_count && qdrant_count != ets_count && abs(qdrant_count - ets_count) > 5 do
      Logger.info("Dashboard: Qdrant has #{qdrant_count} points but ETS has #{ets_count}, syncing...")
      safe_call(fn -> ElixirNexus.ProjectSwitcher.reload_from_qdrant() end, :ok)
      {:synced, add_activity(socket, :synced, "Synced from Qdrant: #{qdrant_count} chunks loaded")}
    else
      {:unchanged, socket}
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

  defp layer_color("ports"), do: "bg-cyan-500/70"
  defp layer_color("adapters"), do: "bg-amber-500/70"
  defp layer_color("application"), do: "bg-sky-500/70"
  defp layer_color("domain"), do: "bg-violet-500/70"
  defp layer_color("repositories"), do: "bg-emerald-500/70"
  defp layer_color("api"), do: "bg-rose-500/70"
  defp layer_color("presentation"), do: "bg-blue-500/70"
  defp layer_color("lib"), do: "bg-teal-500/70"
  defp layer_color(_), do: "bg-slate-500/70"
end
