defmodule ElixirNexus.VectorsLive.Index do
  @moduledoc false
  use Phoenix.LiveView
  import ElixirNexusWeb.CoreComponents

  @per_page 20

  def render(assigns) do
    ~H"""
    <h2 class="text-2xl font-bold text-white mb-6">Vector Store</h2>

    <!-- Collection Stats -->
    <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-6">
      <.stat_card label="Total Points" value={@points_count} color="blue" animated />
      <.stat_card label="Collection" value={@collection_name} color="white" />
      <.stat_card label="Status" value={@collection_status} color="emerald" />
      <.stat_card label="Segments" value={@segments_count} color="violet" animated />
    </div>

    <!-- Entity Type Distribution Mini Bar -->
    <%= if @entity_type_dist != [] do %>
      <div class="flex gap-1 mb-6 h-2 rounded-full overflow-hidden bg-slate-800">
        <%= for {type, count} <- @entity_type_dist do %>
          <div
            class={"h-full #{dist_bar_color(type)}"}
            style={"width: #{bar_pct(count, @points_count)}%"}
            title={"#{type}: #{count}"}
          ></div>
        <% end %>
      </div>
    <% end %>

    <!-- Actions -->
    <div class="flex gap-3 mb-6">
      <button
        phx-click="refresh"
        class="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg text-sm font-medium transition"
      >
        Refresh
      </button>
      <button
        phx-click="reindex"
        class={"px-4 py-2 bg-indigo-600 hover:bg-indigo-700 text-white rounded-lg text-sm font-medium transition #{if @reindexing, do: "opacity-50 cursor-not-allowed", else: ""}"}
        disabled={@reindexing}
      >
        <%= if @reindexing, do: "Re-indexing...", else: "Re-index Codebase" %>
      </button>
      <button
        phx-click="confirm_reset"
        class="px-4 py-2 bg-red-600/80 hover:bg-red-600 text-white rounded-lg text-sm font-medium transition"
      >
        Reset Collection
      </button>
      <button
        phx-click="confirm_delete"
        class="px-4 py-2 bg-red-800/80 hover:bg-red-800 text-white rounded-lg text-sm font-medium transition"
      >
        Delete Collection
      </button>
      <%= if @confirm_reset do %>
        <div class="flex items-center gap-2 bg-red-900/30 border border-red-700/50 rounded-lg px-4 py-2">
          <span class="text-red-300 text-sm">Delete all vectors?</span>
          <button phx-click="reset_collection" class="px-3 py-1 bg-red-600 hover:bg-red-700 text-white rounded text-sm font-medium">Yes, reset</button>
          <button phx-click="cancel_reset" class="px-3 py-1 bg-slate-600 hover:bg-slate-700 text-white rounded text-sm font-medium">Cancel</button>
        </div>
      <% end %>
      <%= if @confirm_delete do %>
        <div class="flex items-center gap-2 bg-red-900/30 border border-red-700/50 rounded-lg px-4 py-2">
          <span class="text-red-300 text-sm">Permanently delete collection "<%= @collection_name %>"?</span>
          <button phx-click="delete_collection" class="px-3 py-1 bg-red-600 hover:bg-red-700 text-white rounded text-sm font-medium">Yes, delete</button>
          <button phx-click="cancel_delete" class="px-3 py-1 bg-slate-600 hover:bg-slate-700 text-white rounded text-sm font-medium">Cancel</button>
        </div>
      <% end %>
    </div>

    <!-- Filter Bar -->
    <div class="flex gap-3 mb-6">
      <form phx-submit="filter" class="flex gap-3 flex-1">
        <select name="entity_type" class="bg-slate-800 border border-slate-600 text-slate-200 rounded-lg px-3 py-2 text-sm">
          <option value="">All types</option>
          <option value="module" selected={@filter_type == "module"}>Modules</option>
          <option value="function" selected={@filter_type == "function"}>Functions</option>
          <option value="macro" selected={@filter_type == "macro"}>Macros</option>
          <option value="struct" selected={@filter_type == "struct"}>Structs</option>
        </select>
        <button type="submit" class="px-4 py-2 bg-slate-700 hover:bg-slate-600 text-white rounded-lg text-sm font-medium transition">
          Filter
        </button>
        <%= if @filter_type != "" do %>
          <button type="button" phx-click="clear_filter" class="px-4 py-2 bg-slate-800 hover:bg-slate-700 text-slate-300 rounded-lg text-sm transition">
            Clear
          </button>
        <% end %>
      </form>
      <div class="text-slate-400 text-sm flex items-center">
        Showing <%= length(@points) %> of <%= @filtered_count %> points
      </div>
    </div>

    <!-- Points Table -->
    <div class="bg-slate-800/30 border border-slate-700/50 rounded-lg overflow-hidden">
      <table class="w-full">
        <thead>
          <tr class="border-b border-slate-700/50">
            <th class="text-left px-4 py-3 text-slate-400 text-xs font-medium uppercase tracking-wider">Name</th>
            <th class="text-left px-4 py-3 text-slate-400 text-xs font-medium uppercase tracking-wider">Type</th>
            <th class="text-left px-4 py-3 text-slate-400 text-xs font-medium uppercase tracking-wider">File</th>
            <th class="text-left px-4 py-3 text-slate-400 text-xs font-medium uppercase tracking-wider">Lines</th>
            <th class="text-left px-4 py-3 text-slate-400 text-xs font-medium uppercase tracking-wider">Visibility</th>
            <th class="text-right px-4 py-3 text-slate-400 text-xs font-medium uppercase tracking-wider">Actions</th>
          </tr>
        </thead>
        <tbody>
          <%= for point <- @points do %>
            <tr class="border-b border-slate-700/30 hover:bg-slate-800/50 transition">
              <td class="px-4 py-3">
                <button
                  phx-click="show_detail"
                  phx-value-id={point.id}
                  class="text-blue-400 hover:text-blue-300 font-medium text-sm hover:underline"
                >
                  <%= point.payload["name"] || "\u2014" %>
                </button>
              </td>
              <td class="px-4 py-3">
                <.entity_badge type={point.payload["entity_type"] || "?"} />
              </td>
              <td class="px-4 py-3 text-slate-400 text-sm truncate max-w-xs" title={point.payload["file_path"]}>
                <%= shorten_path(point.payload["file_path"]) %>
              </td>
              <td class="px-4 py-3 text-slate-500 text-sm">
                <%= point.payload["start_line"] %>\u2013<%= point.payload["end_line"] %>
              </td>
              <td class="px-4 py-3 text-slate-500 text-sm">
                <%= point.payload["visibility"] || "\u2014" %>
              </td>
              <td class="px-4 py-3 text-right">
                <button
                  phx-click="delete_point"
                  phx-value-id={point.id}
                  class="text-red-400/60 hover:text-red-400 text-sm transition"
                >
                  Delete
                </button>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>

    <!-- Pagination -->
    <div class="flex justify-between items-center mt-4">
      <div class="text-slate-500 text-sm">Page <%= @page + 1 %></div>
      <div class="flex gap-2">
        <button
          phx-click="prev_page"
          disabled={@page == 0}
          class={"px-4 py-2 rounded-lg text-sm font-medium transition #{if @page == 0, do: "bg-slate-800 text-slate-600 cursor-not-allowed", else: "bg-slate-700 text-white hover:bg-slate-600"}"}
        >
          Previous
        </button>
        <button
          phx-click="next_page"
          disabled={@next_offset == nil}
          class={"px-4 py-2 rounded-lg text-sm font-medium transition #{if @next_offset == nil, do: "bg-slate-800 text-slate-600 cursor-not-allowed", else: "bg-slate-700 text-white hover:bg-slate-600"}"}
        >
          Next
        </button>
      </div>
    </div>

    <!-- Detail Modal -->
    <%= if @detail_point do %>
      <div class="fixed inset-0 bg-black/60 z-50 flex items-center justify-center p-6" phx-click="close_detail">
        <div class="bg-slate-800 border border-slate-600 rounded-xl max-w-3xl w-full max-h-[80vh] overflow-auto" phx-click-away="close_detail">
          <div class="flex justify-between items-center border-b border-slate-700 px-6 py-4">
            <h3 class="text-xl font-bold text-white"><%= @detail_point["payload"]["name"] %></h3>
            <button phx-click="close_detail" class="text-slate-400 hover:text-white text-xl">&times;</button>
          </div>
          <div class="px-6 py-4 space-y-4">
            <div class="grid grid-cols-2 gap-4">
              <div>
                <p class="text-slate-400 text-xs uppercase mb-1">Type</p>
                <p class="text-white text-sm"><%= @detail_point["payload"]["entity_type"] %></p>
              </div>
              <div>
                <p class="text-slate-400 text-xs uppercase mb-1">File</p>
                <p class="text-white text-sm break-all"><%= @detail_point["payload"]["file_path"] %></p>
              </div>
              <div>
                <p class="text-slate-400 text-xs uppercase mb-1">Lines</p>
                <p class="text-white text-sm"><%= @detail_point["payload"]["start_line"] %> \u2013 <%= @detail_point["payload"]["end_line"] %></p>
              </div>
              <div>
                <p class="text-slate-400 text-xs uppercase mb-1">Visibility</p>
                <p class="text-white text-sm"><%= @detail_point["payload"]["visibility"] || "\u2014" %></p>
              </div>
              <div>
                <p class="text-slate-400 text-xs uppercase mb-1">Point ID</p>
                <p class="text-white text-sm font-mono"><%= @detail_point["id"] %></p>
              </div>
              <div>
                <p class="text-slate-400 text-xs uppercase mb-1">Parameters</p>
                <p class="text-white text-sm"><%= Enum.join(@detail_point["payload"]["parameters"] || [], ", ") |> then(fn s -> if s == "", do: "\u2014", else: s end) %></p>
              </div>
            </div>

            <%= if length(@detail_point["payload"]["calls"] || []) > 0 do %>
              <div>
                <p class="text-slate-400 text-xs uppercase mb-1">Calls</p>
                <div class="flex flex-wrap gap-1">
                  <%= for call <- @detail_point["payload"]["calls"] || [] do %>
                    <span class="bg-slate-700 text-slate-300 px-2 py-0.5 rounded text-xs"><%= call %></span>
                  <% end %>
                </div>
              </div>
            <% end %>

            <%= if length(@detail_point["payload"]["is_a"] || []) > 0 do %>
              <div>
                <p class="text-slate-400 text-xs uppercase mb-1">Uses / Imports</p>
                <div class="flex flex-wrap gap-1">
                  <%= for mod <- @detail_point["payload"]["is_a"] || [] do %>
                    <span class="bg-indigo-900/50 text-indigo-300 px-2 py-0.5 rounded text-xs"><%= mod %></span>
                  <% end %>
                </div>
              </div>
            <% end %>

            <%= if length(@detail_point["payload"]["contains"] || []) > 0 do %>
              <div>
                <p class="text-slate-400 text-xs uppercase mb-1">Contains</p>
                <div class="flex flex-wrap gap-1">
                  <%= for item <- @detail_point["payload"]["contains"] || [] do %>
                    <span class="bg-emerald-900/50 text-emerald-300 px-2 py-0.5 rounded text-xs"><%= item %></span>
                  <% end %>
                </div>
              </div>
            <% end %>

            <div>
              <p class="text-slate-400 text-xs uppercase mb-1">Content</p>
              <pre class="bg-slate-900 border border-slate-700 rounded-lg p-4 text-slate-300 text-xs overflow-x-auto whitespace-pre-wrap"><%= @detail_point["payload"]["content"] %></pre>
            </div>

            <%= if @detail_point["vector_preview"] do %>
              <div>
                <p class="text-slate-400 text-xs uppercase mb-1">Vector (first 10 dims)</p>
                <p class="text-slate-500 text-xs font-mono">
                  [<%= @detail_point["vector_preview"] |> Enum.map(&Float.round(&1, 6)) |> Enum.join(", ") %>...]
                </p>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    <% end %>

    <!-- Flash messages -->
    <%= if @flash_message do %>
      <div class={"fixed bottom-6 right-6 px-6 py-3 rounded-lg shadow-lg text-sm font-medium z-50 #{if @flash_type == :error, do: "bg-red-600 text-white", else: "bg-emerald-600 text-white"}"}>
        <%= @flash_message %>
      </div>
    <% end %>
    """
  end

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        current_path: "/vectors",
        collection_name: ElixirNexus.QdrantClient.collection_name(),
        points_count: 0,
        collection_status: "loading",
        segments_count: 0,
        points: [],
        page: 0,
        next_offset: nil,
        offset_stack: [],
        filter_type: "",
        filtered_count: 0,
        detail_point: nil,
        confirm_reset: false,
        confirm_delete: false,
        reindexing: false,
        flash_message: nil,
        flash_type: :info,
        entity_type_dist: []
      )

    if connected?(socket) do
      ElixirNexus.Events.subscribe_indexing()
    end

    socket = load_collection_info(socket)
    socket = load_points(socket)
    {:ok, socket}
  end

  def handle_params(_params, uri, socket) do
    {:noreply, assign(socket, current_path: URI.parse(uri).path)}
  end

  def handle_event("switch_collection", %{"collection" => name}, socket) do
    ElixirNexus.ProjectSwitcher.switch_project(name)
    {:noreply, socket}
  end

  def handle_event("refresh", _params, socket) do
    socket =
      socket
      |> load_collection_info()
      |> load_points()
      |> set_flash("Refreshed", :info)

    {:noreply, socket}
  end

  def handle_event("filter", %{"entity_type" => type}, socket) do
    socket =
      socket
      |> assign(filter_type: type, page: 0, offset_stack: [], next_offset: nil)
      |> load_points()

    {:noreply, socket}
  end

  def handle_event("clear_filter", _params, socket) do
    socket =
      socket
      |> assign(filter_type: "", page: 0, offset_stack: [], next_offset: nil)
      |> load_points()

    {:noreply, socket}
  end

  def handle_event("next_page", _params, %{assigns: %{next_offset: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("next_page", _params, socket) do
    current_offset = socket.assigns.next_offset

    socket =
      socket
      |> assign(
        page: socket.assigns.page + 1,
        offset_stack: [current_offset | socket.assigns.offset_stack]
      )
      |> load_points(current_offset)

    {:noreply, socket}
  end

  def handle_event("prev_page", _params, %{assigns: %{page: 0}} = socket) do
    {:noreply, socket}
  end

  def handle_event("prev_page", _params, socket) do
    {_prev_offset, remaining} =
      case socket.assigns.offset_stack do
        [h | t] -> {h, t}
        [] -> {nil, []}
      end

    page_offset =
      case remaining do
        [offset | _] -> offset
        [] -> nil
      end

    socket =
      socket
      |> assign(page: socket.assigns.page - 1, offset_stack: remaining)
      |> load_points(page_offset)

    {:noreply, socket}
  end

  def handle_event("show_detail", %{"id" => id}, socket) do
    parsed_id = parse_id(id)

    case ElixirNexus.QdrantClient.get_point(parsed_id) do
      {:ok, data} ->
        point = data["result"]

        vector_preview = case point["vector"] do
          v when is_list(v) -> Enum.take(v, 10)
          _ -> []
        end

        detail = %{
          "id" => point["id"],
          "payload" => point["payload"] || %{},
          "vector_preview" => vector_preview
        }

        {:noreply, assign(socket, detail_point: detail)}

      {:error, _} ->
        {:noreply, set_flash(socket, "Failed to load point", :error)}
    end
  end

  def handle_event("close_detail", _params, socket) do
    {:noreply, assign(socket, detail_point: nil)}
  end

  def handle_event("delete_point", %{"id" => id}, socket) do
    parsed_id = parse_id(id)

    case ElixirNexus.QdrantClient.delete_points([parsed_id]) do
      {:ok, _} ->
        socket =
          socket
          |> load_collection_info()
          |> load_points()
          |> set_flash("Point deleted", :info)

        {:noreply, socket}

      {:error, _} ->
        {:noreply, set_flash(socket, "Failed to delete point", :error)}
    end
  end

  def handle_event("confirm_reset", _params, socket) do
    {:noreply, assign(socket, confirm_reset: true)}
  end

  def handle_event("cancel_reset", _params, socket) do
    {:noreply, assign(socket, confirm_reset: false)}
  end

  def handle_event("confirm_delete", _params, socket) do
    {:noreply, assign(socket, confirm_delete: true)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, confirm_delete: false)}
  end

  def handle_event("delete_collection", _params, socket) do
    case ElixirNexus.QdrantClient.delete_collection() do
      {:ok, _} ->
        ElixirNexus.ChunkCache.clear()
        ElixirNexus.GraphCache.clear()

        # Switch to first available collection or broadcast nil
        case ElixirNexus.QdrantClient.list_collections() do
          {:ok, [first | _]} ->
            ElixirNexus.ProjectSwitcher.switch_project(first)

          _ ->
            ElixirNexus.Events.broadcast_collection_changed(nil)
        end

        socket =
          socket
          |> assign(confirm_delete: false, page: 0, offset_stack: [], next_offset: nil)
          |> load_collection_info()
          |> load_points()
          |> set_flash("Collection deleted", :info)

        {:noreply, socket}

      {:error, _} ->
        {:noreply, set_flash(socket, "Failed to delete collection", :error)}
    end
  end

  def handle_event("reset_collection", _params, socket) do
    case ElixirNexus.QdrantClient.reset_collection() do
      {:ok, _} ->
        socket =
          socket
          |> assign(confirm_reset: false, page: 0, offset_stack: [], next_offset: nil)
          |> load_collection_info()
          |> load_points()
          |> set_flash("Collection reset", :info)

        {:noreply, socket}

      {:error, _} ->
        {:noreply, set_flash(socket, "Failed to reset collection", :error)}
    end
  end

  def handle_event("reindex", _params, socket) do
    self_pid = self()
    socket = assign(socket, reindexing: true)

    Task.start(fn ->
      result = ElixirNexus.Indexer.index_directory(File.cwd!() <> "/lib")
      send(self_pid, {:reindex_done, result})
    end)

    {:noreply, set_flash(socket, "Re-indexing started...", :info)}
  end

  def handle_info({:reindex_done, {:ok, status}}, socket) do
    socket =
      socket
      |> assign(reindexing: false)
      |> load_collection_info()
      |> load_points()
      |> set_flash("Re-indexed: #{status.indexed_files} files, #{status.total_chunks} chunks", :info)

    {:noreply, socket}
  end

  def handle_info({:reindex_done, {:error, reason}}, socket) do
    socket =
      socket
      |> assign(reindexing: false)
      |> set_flash("Re-index failed: #{inspect(reason)}", :error)

    {:noreply, socket}
  end

  def handle_info({:indexing_complete, _data}, socket) do
    socket =
      socket
      |> load_collection_info()
      |> load_points()
      |> set_flash("Index updated!", :info)

    {:noreply, socket}
  end

  def handle_info({:indexing_progress, _data}, socket) do
    socket = load_collection_info(socket)
    {:noreply, socket}
  end

  def handle_info({:file_reindexed, _path}, socket) do
    socket =
      socket
      |> load_collection_info()
      |> load_points()

    {:noreply, socket}
  end

  def handle_info({:collection_changed, name}, socket) do
    socket =
      socket
      |> assign(
        collection_name: name,
        page: 0,
        offset_stack: [],
        next_offset: nil
      )
      |> load_collection_info()
      |> load_points()

    {:noreply, socket}
  end

  def handle_info(:clear_flash, socket) do
    {:noreply, assign(socket, flash_message: nil)}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # --- Helpers ---

  defp load_collection_info(socket) do
    case ElixirNexus.QdrantClient.collection_info() do
      {:ok, data} ->
        result = data["result"]

        assign(socket,
          points_count: result["points_count"] || 0,
          collection_status: result["status"] || "unknown",
          segments_count: length(result["segments"] || [])
        )

      {:error, _} ->
        assign(socket, collection_status: "error")
    end
  end

  defp load_points(socket, offset \\ nil) do
    filter = build_filter(socket.assigns.filter_type)

    case ElixirNexus.QdrantClient.scroll_points(@per_page, offset, filter) do
      {:ok, data} ->
        points =
          (data["result"]["points"] || [])
          |> Enum.map(fn p -> %{id: p["id"], payload: p["payload"] || %{}} end)

        filtered_count = get_filtered_count(filter)

        # Compute entity type distribution
        entity_type_dist =
          points
          |> Enum.group_by(fn p -> p.payload["entity_type"] || "unknown" end)
          |> Enum.map(fn {type, ps} -> {type, length(ps)} end)
          |> Enum.sort_by(fn {_, c} -> -c end)

        assign(socket,
          points: points,
          next_offset: data["result"]["next_page_offset"],
          filtered_count: filtered_count,
          entity_type_dist: entity_type_dist
        )

      {:error, _} ->
        assign(socket, points: [])
    end
  end

  defp get_filtered_count(filter) do
    case ElixirNexus.QdrantClient.count_points(filter) do
      {:ok, data} -> data["result"]["count"] || 0
      _ -> 0
    end
  end

  defp build_filter(""), do: nil

  defp build_filter(type) do
    %{"must" => [%{"key" => "entity_type", "match" => %{"value" => type}}]}
  end

  defp set_flash(socket, message, type) do
    if socket.assigns[:flash_timer], do: Process.cancel_timer(socket.assigns.flash_timer)
    timer = Process.send_after(self(), :clear_flash, 4000)
    assign(socket, flash_message: message, flash_type: type, flash_timer: timer)
  end

  defp shorten_path(nil), do: "\u2014"

  defp shorten_path(path) do
    case String.split(path, "/lib/") do
      [_, rest] -> "lib/" <> rest
      _ -> path
    end
  end

  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> id
    end
  end

  defp bar_pct(_count, 0), do: 0
  defp bar_pct(count, total), do: min(round(count / total * 100), 100)

  defp dist_bar_color("module"), do: "bg-purple-500"
  defp dist_bar_color("function"), do: "bg-sky-500"
  defp dist_bar_color("macro"), do: "bg-amber-500"
  defp dist_bar_color("struct"), do: "bg-emerald-500"
  defp dist_bar_color(_), do: "bg-slate-500"
end
