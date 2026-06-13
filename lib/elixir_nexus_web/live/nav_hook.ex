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
    all =
      case ElixirNexus.QdrantClient.list_collections() do
        {:ok, names} -> names
        _ -> []
      end

    active = ElixirNexus.QdrantClient.active_collection()
    collections = visible_collections(all, active)

    # Only realign if the active collection genuinely no longer exists in Qdrant
    # (deleted externally). Do NOT hijack it to an arbitrary collection just
    # because a list call was transiently stale — that fought MCP-driven switches.
    active =
      if active in all or all == [] do
        active
      else
        case collections do
          [first | _] ->
            ElixirNexus.QdrantClient.switch_collection_force(first)
            first

          [] ->
            active
        end
      end

    socket
    |> assign(:collections, collections)
    |> assign(:active_collection, active)
  end

  defp handle_info({:collection_changed, name}, socket) do
    collections =
      case ElixirNexus.QdrantClient.list_collections() do
        {:ok, names} -> visible_collections(names, name)
        _ -> socket.assigns.collections
      end

    {:cont, assign(socket, active_collection: name, collections: collections)}
  end

  defp handle_info(_msg, socket), do: {:cont, socket}

  # Hide test/temp collections, but always keep the active one selectable so the
  # dropdown never "loses" it (which previously triggered an auto-switch to junk).
  defp visible_collections(names, active) do
    real = Enum.reject(names, &ElixirNexus.QdrantClient.test_collection?/1)
    if active in names and active not in real, do: [active | real], else: real
  end
end
