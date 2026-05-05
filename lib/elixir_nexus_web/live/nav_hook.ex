defmodule ElixirNexusWeb.NavHook do
  @moduledoc "on_mount hook for shared navigation state across all LiveViews."
  import Phoenix.LiveView
  import Phoenix.Component

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> attach_hook(:nav_handle_info, :handle_info, &handle_info/2)
      |> assign(:current_path, nil)
      |> assign_collections()

    if connected?(socket) do
      ElixirNexus.Events.subscribe_collection()
    end

    {:cont, socket}
  end

  defp assign_collections(socket) do
    collections =
      case ElixirNexus.QdrantClient.list_collections() do
        {:ok, names} -> filter_collections(names)
        _ -> []
      end

    active = ElixirNexus.QdrantClient.active_collection()

    socket
    |> assign(:collections, collections)
    |> assign(:active_collection, active)
  end

  defp handle_info({:collection_changed, name}, socket) do
    collections =
      case ElixirNexus.QdrantClient.list_collections() do
        {:ok, names} -> filter_collections(names)
        _ -> socket.assigns.collections
      end

    {:cont, assign(socket, active_collection: name, collections: collections)}
  end

  defp handle_info(_msg, socket), do: {:cont, socket}

  defp filter_collections(names) do
    Enum.reject(names, &String.ends_with?(&1, "_test"))
  end
end
