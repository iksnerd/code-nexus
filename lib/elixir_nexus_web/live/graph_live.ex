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
            <span class="w-2 h-2 rounded-full bg-purple-500"></span> Method
          </span>
          <span class="flex items-center gap-1.5 text-xs text-slate-400">
            <span class="w-2 h-2 rounded-full bg-amber-500"></span> Struct
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

         <!-- Select mode: nodes vs package boxes -->
         <div class="bg-slate-900/80 backdrop-blur-md border border-slate-700 rounded-lg p-2 w-48">
           <p class="text-[10px] text-slate-500 uppercase tracking-wider mb-1.5">Select</p>
           <div class="flex gap-1 bg-slate-800/60 rounded-md p-0.5">
             <button onclick="window.graphControls.setMode('nodes'); window.segActivate(this)"
                     class="flex-1 px-2 py-1 rounded text-xs font-medium bg-blue-600 text-white">Nodes</button>
             <button onclick="window.graphControls.setMode('boxes'); window.segActivate(this)"
                     class="flex-1 px-2 py-1 rounded text-xs font-medium text-slate-400">Boxes</button>
           </div>
         </div>

         <!-- Edge-type filter -->
         <div class="bg-slate-900/80 backdrop-blur-md border border-slate-700 rounded-lg p-2 w-48">
           <p class="text-[10px] text-slate-500 uppercase tracking-wider mb-1.5">Edges</p>
           <div class="flex gap-1 bg-slate-800/60 rounded-md p-0.5">
             <button onclick="window.graphControls.linkFilter('all'); window.segActivate(this)"
                     class="flex-1 px-1.5 py-1 rounded text-[11px] font-medium bg-blue-600 text-white">All</button>
             <button onclick="window.graphControls.linkFilter('calls'); window.segActivate(this)"
                     class="flex-1 px-1.5 py-1 rounded text-[11px] font-medium text-slate-400">Calls</button>
             <button onclick="window.graphControls.linkFilter('imports'); window.segActivate(this)"
                     class="flex-1 px-1.5 py-1 rounded text-[11px] font-medium text-slate-400">Imports</button>
             <button onclick="window.graphControls.linkFilter('contains'); window.segActivate(this)"
                     class="flex-1 px-1.5 py-1 rounded text-[11px] font-medium text-slate-400">Contains</button>
           </div>
         </div>

         <!-- Layout settings — live D3 force tuning -->
         <details class="bg-slate-900/80 backdrop-blur-md border border-slate-700 rounded-lg text-xs text-slate-400 w-48">
           <summary class="px-3 py-2 cursor-pointer select-none hover:text-slate-200 flex items-center gap-1.5">
             <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" viewBox="0 0 20 20" fill="currentColor"><path fill-rule="evenodd" d="M11.49 3.17c-.38-1.56-2.6-1.56-2.98 0a1.532 1.532 0 01-2.286.948c-1.372-.836-2.942.734-2.106 2.106.54.886.061 2.042-.947 2.287-1.561.379-1.561 2.6 0 2.978a1.532 1.532 0 01.947 2.287c-.836 1.372.734 2.942 2.106 2.106a1.532 1.532 0 012.287.947c.379 1.561 2.6 1.561 2.978 0a1.533 1.533 0 012.287-.947c1.372.836 2.942-.734 2.106-2.106a1.533 1.533 0 01.947-2.287c1.561-.379 1.561-2.6 0-2.978a1.532 1.532 0 01-.947-2.287c.836-1.372-.734-2.942-2.106-2.106a1.532 1.532 0 01-2.287-.947zM10 13a3 3 0 100-6 3 3 0 000 6z" clip-rule="evenodd" /></svg>
             Layout
           </summary>
           <div class="px-3 pb-3 pt-1 flex flex-col gap-2.5">
             <label class="flex flex-col gap-1">
               <span>Link distance</span>
               <input type="range" min="0.4" max="2.5" step="0.1" value="1"
                      oninput="window.graphControls && window.graphControls.linkDistance(this.value)" class="w-full accent-blue-500" />
             </label>
             <label class="flex flex-col gap-1">
               <span>Repulsion</span>
               <input type="range" min="-1500" max="-100" step="50" value="-520"
                      oninput="window.graphControls && window.graphControls.charge(this.value)" class="w-full accent-blue-500" />
             </label>
             <label class="flex flex-col gap-1">
               <span>Spacing</span>
               <input type="range" min="10" max="70" step="2" value="30"
                      oninput="window.graphControls && window.graphControls.spacing(this.value)" class="w-full accent-blue-500" />
             </label>
             <label class="flex flex-col gap-1">
               <span>Cluster tightness</span>
               <input type="range" min="0.05" max="0.95" step="0.05" value="0.45"
                      oninput="window.graphControls && window.graphControls.cluster(this.value)" class="w-full accent-blue-500" />
             </label>

             <hr class="border-slate-700/60 my-1" />

             <label class="flex flex-col gap-1">
               <span>Min connections <span class="text-slate-500" id="minconn-val">0</span></span>
               <input type="range" min="0" max="20" step="1" value="0"
                      oninput="window.graphControls && window.graphControls.minConnections(this.value); document.getElementById('minconn-val').textContent = this.value" class="w-full accent-blue-500" />
             </label>

             <div class="flex flex-col gap-1">
               <span>Labels</span>
               <div class="flex gap-1 bg-slate-800/60 rounded-md p-0.5">
                 <button onclick="window.graphControls.labels('auto'); window.segActivate(this)"
                         class="flex-1 px-1.5 py-1 rounded text-[11px] font-medium bg-blue-600 text-white">Auto</button>
                 <button onclick="window.graphControls.labels('all'); window.segActivate(this)"
                         class="flex-1 px-1.5 py-1 rounded text-[11px] font-medium text-slate-400">All</button>
                 <button onclick="window.graphControls.labels('none'); window.segActivate(this)"
                         class="flex-1 px-1.5 py-1 rounded text-[11px] font-medium text-slate-400">None</button>
               </div>
             </div>

             <label class="flex items-center gap-2 cursor-pointer pt-0.5">
               <input type="checkbox"
                      onchange="window.graphControls.toggleType('variable', this.checked)" class="accent-blue-500" />
               <span>Hide variables</span>
             </label>

             <p class="text-[10px] text-slate-500 leading-snug pt-0.5">In <b>Boxes</b> mode, click a package to isolate it; click empty space to clear.</p>
           </div>
         </details>
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

  def handle_info({:collection_changed, _name}, socket) do
    send(self(), :load_graph)
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @max_graph_nodes 500

  # Group key for spatial clustering. The natural unit differs by language, so
  # dispatch on the file extension — Go clusters by package (== its directory),
  # other languages fall back to the source folder. This is the seam to specialize
  # per language (e.g. Elixir module namespace, Java package from `package` decl).
  # Nodes sharing a group are pulled together so the graph mirrors the codebase's
  # structure instead of hairballing.
  # Framework/utility name noise — single-char locals, common loop/error vars, and short
  # PascalCase wrapper aliases (Comp, Slot, Box…). Kept in sync with GraphStats' filter.
  @graph_noise_names ~w(cn clsx cva classnames twMerge cx Comp Slot forwardRef
    createContext useContext createElement createPortal createRef memo Fragment Children
    React i j k e x err key idx tmp val acc el ref ctx ev)

  defp graph_noise_name?(name) do
    name == "" or String.length(name) <= 2 or name in @graph_noise_names or
      Regex.match?(~r/^[A-Z][a-z]{0,3}$/, name) or
      String.starts_with?(name, "[") or String.starts_with?(name, "{") or
      String.contains?(name, ",")
  end

  defp group_for(nil), do: "?"

  defp group_for(path) do
    path = to_string(path)

    case Path.extname(path) do
      # Go: one package per directory — the directory IS the package.
      ".go" -> dir_group(path)
      # Default: cluster by source folder (works for JS/TS/Python/Rust/etc.).
      _ -> dir_group(path)
    end
  end

  # Last two path segments of the file's directory, e.g. "internal/tracker", "cmd/wl".
  defp dir_group(path) do
    path |> Path.dirname() |> Path.split() |> Enum.take(-2) |> Enum.join("/")
  end

  defp build_d3_graph do
    nodes_map = ElixirNexus.GraphCache.all_nodes()

    # Create list of nodes, capped to top N by degree to avoid overwhelming the browser
    nodes =
      nodes_map
      # Drop framework/utility name noise (single-char locals like `i`/`e`, shadcn wrapper
      # aliases like `Comp`/`Slot`, short PascalCase) — these aren't meaningful code entities
      # and otherwise render as large junk blobs. Mirrors the GraphStats noise filter.
      |> Enum.reject(fn {_id, node} -> graph_noise_name?(node["name"] || "") end)
      |> Enum.map(fn {id, node} ->
        %{
          id: id,
          name: node["name"],
          type: node["entity_type"] || node["type"] || "unknown",
          file: node["file_path"] |> to_string() |> String.replace_leading("/app/", ""),
          group: group_for(node["file_path"]),
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

    # id → package (last segment of its group), so cross-package calls written as
    # `pkg.Func` can resolve to the bare-named `Func` node in package `pkg`.
    pkg_of =
      nodes_map
      |> Enum.reduce(%{}, fn {id, node}, acc ->
        Map.put(acc, id, group_for(node["file_path"]) |> String.split("/") |> List.last())
      end)

    # Resolve a callee name to target node ids: exact match first; for qualified
    # `pkg.Func` calls, the bare `Func` in the matching package; else an
    # unambiguous bare match anywhere. This is what connects the package boxes —
    # without it, qualified cross-package calls leave whole packages isolated.
    resolve_targets = fn raw ->
      lower = String.downcase(raw)

      case Map.get(name_to_ids, lower, []) do
        [] ->
          parts = String.split(lower, ".")

          if length(parts) >= 2 do
            bare = List.last(parts)
            prefix = Enum.at(parts, -2)
            by_bare = Map.get(name_to_ids, bare, [])
            pkg_matched = Enum.filter(by_bare, &(Map.get(pkg_of, &1) == prefix))

            cond do
              pkg_matched != [] -> pkg_matched
              match?([_], by_bare) -> by_bare
              true -> []
            end
          else
            []
          end

        ids ->
          ids
      end
    end

    links =
      nodes_map
      |> Enum.flat_map(fn {id, node} ->
        if MapSet.member?(node_ids, id) do
          call_links =
            (node["calls"] || [])
            |> Enum.flat_map(fn callee_name ->
              resolve_targets.(callee_name)
              |> Enum.filter(&MapSet.member?(node_ids, &1))
              |> Enum.reject(&(&1 == id))
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

          parent_lower = String.downcase(node["name"] || "")

          contains_links =
            (node["contains"] || [])
            |> Enum.flat_map(fn child_name ->
              child_lower = String.downcase(child_name)

              # `contains` stores bare child names (struct fields + method names),
              # but method nodes are receiver-qualified ("Struct.method"). Try both
              # the bare name and the "<parent>.<child>" form so struct→method
              # containment actually resolves to a link.
              target_ids =
                Map.get(name_to_ids, child_lower, []) ++
                  Map.get(name_to_ids, "#{parent_lower}.#{child_lower}", [])

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
