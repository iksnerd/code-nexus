defmodule ElixirNexus.GraphLive.Index do
  @moduledoc false
  use Phoenix.LiveView

  def render(assigns) do
    ~H"""
    <div class="flex items-center justify-between mb-6">
      <h2 class="text-2xl font-bold text-white">Code Relationship Graph</h2>
      <div class="flex gap-4 items-center">
        <div class="flex gap-2 text-sm text-slate-400 mr-4">
          <span>Nodes: <b class="text-white"><%= @nodes_count %></b></span>
          <span>Links: <b class="text-white"><%= @links_count %></b></span>
        </div>
        <div class="flex gap-3">
          <span class="flex items-center gap-1.5 text-xs text-slate-400">
            <span class="w-2 h-2 rounded-full bg-blue-500"></span> Module
          </span>
          <span class="flex items-center gap-1.5 text-xs text-slate-400">
            <span class="w-2 h-2 rounded-full bg-emerald-500"></span> Function
          </span>
          <span class="flex items-center gap-1.5 text-xs text-slate-400">
            <span class="w-6 border-t-2 border-slate-500"></span> Calls
          </span>
          <span class="flex items-center gap-1.5 text-xs text-slate-400">
            <span class="w-6 border-t-2 border-dashed border-amber-500"></span> Imports
          </span>
          <span class="flex items-center gap-1.5 text-xs text-slate-400">
            <span class="w-6 border-t-2 border-dotted border-indigo-500"></span> Contains
          </span>
        </div>
        <button
          phx-click="refresh_graph"
          class="px-4 py-1.5 bg-slate-800 hover:bg-slate-700 text-slate-300 text-sm font-medium rounded-lg border border-slate-700 transition"
        >
          Refresh
        </button>
      </div>
    </div>

    <div class="relative bg-slate-900/50 border border-slate-800 rounded-xl overflow-hidden" style="height: 700px;">
      <%= if @nodes_count == 0 do %>
        <div class="absolute inset-0 flex flex-col items-center justify-center bg-slate-900/90 backdrop-blur-sm z-20">
          <svg class="w-16 h-16 text-slate-500 mb-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 002-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10" />
          </svg>
          <p class="text-xl text-white font-medium">No Graph Data Available</p>
          <p class="text-slate-400 mt-2">The index might be empty. Try running a search or ensuring a project is indexed.</p>
        </div>
      <% end %>

      <div
        id="code-graph-container"
        phx-hook="CodeGraph"
        phx-update="ignore"
        class="w-full h-full"
      >
        <svg id="code-graph-svg" class="w-full h-full cursor-move"></svg>
      </div>

      <!-- Graph Overlay UI -->
      <div class="absolute bottom-4 left-4 p-4 bg-slate-900/90 backdrop-blur-md border border-slate-700 rounded-lg shadow-xl pointer-events-none transition-opacity duration-300 opacity-0 z-10" style="max-width: 340px;" id="node-details">
        <div class="flex items-center gap-2 mb-1">
          <span id="node-type-badge" class="px-1.5 py-0.5 rounded text-[10px] font-bold uppercase tracking-wider bg-blue-500/20 text-blue-400">module</span>
          <h3 id="node-name" class="text-white font-bold truncate text-sm">Node Name</h3>
        </div>
        <p id="node-file" class="text-xs text-slate-500 truncate mb-2 font-mono">file/path/here.ex</p>
        <div class="flex gap-3 text-xs text-slate-400 mb-2">
          <span>Lines: <b id="node-lines" class="text-slate-300">?</b></span>
          <span>Calls: <b id="node-calls" class="text-emerald-400">0</b></span>
          <span>Called by: <b id="node-callers" class="text-blue-400">0</b></span>
          <span>Imports: <b id="node-imports" class="text-amber-400">0</b></span>
        </div>
        <div id="node-calls-list" class="hidden">
          <p class="text-[10px] text-slate-500 uppercase tracking-wider mb-1">Calls</p>
          <div id="node-calls-items" class="flex flex-wrap gap-1 mb-2"></div>
        </div>
        <div id="node-imports-list" class="hidden">
          <p class="text-[10px] text-slate-500 uppercase tracking-wider mb-1">Imports</p>
          <div id="node-imports-items" class="flex flex-wrap gap-1"></div>
        </div>
      </div>

      <div class="absolute top-4 right-4 flex flex-col gap-2 z-10">
         <div class="bg-slate-900/80 backdrop-blur-md border border-slate-700 rounded-lg p-2 flex flex-col gap-1">
            <button onclick="window.zoomIn()" class="p-1.5 hover:bg-slate-800 rounded text-slate-400" title="Zoom In">
              <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" viewBox="0 0 20 20" fill="currentColor"><path fill-rule="evenodd" d="M10 5a1 1 0 011 1v3h3a1 1 0 110 2h-3v3a1 1 0 11-2 0v-3H6a1 1 0 110-2h3V6a1 1 0 011-1z" clip-rule="evenodd" /></svg>
            </button>
            <button onclick="window.zoomOut()" class="p-1.5 hover:bg-slate-800 rounded text-slate-400" title="Zoom Out">
              <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" viewBox="0 0 20 20" fill="currentColor"><path fill-rule="evenodd" d="M5 10a1 1 0 011-1h8a1 1 0 110 2H6a1 1 0 01-1-1z" clip-rule="evenodd" /></svg>
            </button>
            <button onclick="window.resetZoom()" class="p-1.5 hover:bg-slate-800 rounded text-slate-400" title="Reset Zoom">
              <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" viewBox="0 0 20 20" fill="currentColor"><path fill-rule="evenodd" d="M4 2a1 1 0 011 1v2.101a7.002 7.002 0 0111.601 2.566 1 1 0 11-1.885.666A5.002 5.002 0 005.999 7H9a1 1 0 110 2H4a1 1 0 01-1-1V3a1 1 0 011-1zm.008 9.057a1 1 0 011.276.61A5.002 5.002 0 0014.001 13H11a1 1 0 110-2h5a1 1 0 011 1v5a1 1 0 11-2 0v-2.101a7.002 7.002 0 01-11.601-2.566 1 1 0 01.61-1.276z" clip-rule="evenodd" /></svg>
            </button>
         </div>
      </div>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to indexing events to refresh graph
      ElixirNexus.Events.subscribe_indexing()
      # Send initial graph data
      send(self(), :load_graph)
    end

    {:ok, assign(socket, current_path: "/graph", nodes_count: 0, links_count: 0)}
  end

  def handle_event("refresh_graph", _params, socket) do
    send(self(), :load_graph)
    {:noreply, socket}
  end

  def handle_event("switch_collection", %{"collection" => name}, socket) do
    ElixirNexus.ProjectSwitcher.switch_project(name)
    send(self(), :load_graph)
    {:noreply, socket}
  end

  def handle_info(:load_graph, socket) do
    graph_data = build_d3_graph()
    
    socket = 
      socket
      |> assign(nodes_count: length(graph_data.nodes))
      |> assign(links_count: length(graph_data.links))
      |> push_event("graph_data", graph_data)
      
    {:noreply, socket}
  end

  def handle_info({:indexing_complete, _data}, socket) do
    send(self(), :load_graph)
    {:noreply, socket}
  end

  def handle_info({:file_reindexed, _path}, socket) do
    send(self(), :load_graph)
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @max_graph_nodes 500

  defp build_d3_graph do
    nodes_map = ElixirNexus.GraphCache.all_nodes()

    # Create list of nodes, capped to top N by degree to avoid overwhelming the browser
    nodes =
      nodes_map
      |> Enum.map(fn {id, node} ->
        %{
          id: id,
          name: node["name"],
          type: node["type"] || "unknown",
          file: node["file_path"] |> to_string() |> String.replace_leading("/app/", ""),
          val: (node["incoming_count"] || 0) + 1,
          calls_count: length(node["calls"] || []),
          callers_count: node["incoming_count"] || 0,
          imports_count: length(node["is_a"] || []),
          contains_count: length(node["contains"] || []),
          lines: "#{node["start_line"] || "?"}–#{node["end_line"] || "?"}",
          calls: Enum.take(node["calls"] || [], 8),
          imports: Enum.take(node["is_a"] || [], 5)
        }
      end)
      |> Enum.sort_by(& &1.val, :desc)
      |> Enum.take(@max_graph_nodes)

    # Build name → [id, ...] index (one name can map to many nodes)
    name_to_ids =
      nodes_map
      |> Enum.reduce(%{}, fn {id, node}, acc ->
        name = String.downcase(node["name"] || "")
        if name != "", do: Map.update(acc, name, [id], &[id | &1]), else: acc
      end)

    node_ids = MapSet.new(nodes, & &1.id)

    links =
      nodes_map
      |> Enum.flat_map(fn {id, node} ->
        if MapSet.member?(node_ids, id) do
          call_links =
            (node["calls"] || [])
            |> Enum.flat_map(fn callee_name ->
              callee_lower = String.downcase(callee_name)
              target_ids = Map.get(name_to_ids, callee_lower, [])

              target_ids
              |> Enum.filter(&MapSet.member?(node_ids, &1))
              |> Enum.map(fn target_id ->
                %{source: id, target: target_id, type: "calls"}
              end)
            end)

          import_links =
            (node["is_a"] || [])
            |> Enum.flat_map(fn import_name ->
              import_lower = String.downcase(import_name)
              target_ids = Map.get(name_to_ids, import_lower, [])

              target_ids
              |> Enum.filter(&MapSet.member?(node_ids, &1))
              |> Enum.map(fn target_id ->
                %{source: id, target: target_id, type: "imports"}
              end)
            end)

          contains_links =
            (node["contains"] || [])
            |> Enum.flat_map(fn child_name ->
              child_lower = String.downcase(child_name)
              target_ids = Map.get(name_to_ids, child_lower, [])

              target_ids
              |> Enum.filter(&MapSet.member?(node_ids, &1))
              |> Enum.map(fn target_id ->
                %{source: id, target: target_id, type: "contains"}
              end)
            end)

          call_links ++ import_links ++ contains_links
        else
          []
        end
      end)
      |> Enum.uniq()

    %{nodes: nodes, links: links}
  end
end
