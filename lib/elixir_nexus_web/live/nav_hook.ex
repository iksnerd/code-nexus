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

    # If the server's active collection isn't in the list (e.g. it was deleted externally
    # or startup defaulted to a non-existent name), silently realign to the first available
    # collection so the dropdown selection and search results stay in sync.
    active =
      if active not in collections and collections != [] do
        first = hd(collections)
        ElixirNexus.QdrantClient.switch_collection_force(first)
        first
      else
        active
      end

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
