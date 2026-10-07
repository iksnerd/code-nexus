defmodule ElixirNexus.IndexScope do
  @moduledoc """
  The roots the active collection was last indexed from.

  Held in the application env, not in the MCP server's state: over Streamable
  HTTP, ExMCP runs every request in a new server process with empty state, so
  roots kept in that state were gone by the next query and the dirty-file pass
  before queries never ran. The roots are tied to the collection they were
  indexed into: after a switch to another collection they are not returned,
  so a reconcile can never purge one project's files against another's roots.
  """

  @key :index_scope

  @doc "Record that `roots` were indexed into the active collection."
  @spec put([String.t()]) :: :ok
  def put(roots) when is_list(roots) do
    Application.put_env(:elixir_nexus, @key, %{
      collection: ElixirNexus.QdrantClient.active_collection(),
      roots: roots
    })
  end

  @doc "The roots indexed into the active collection, or `[]` when none were recorded for it."
  @spec roots() :: [String.t()]
  def roots do
    case Application.get_env(:elixir_nexus, @key) do
      %{collection: collection, roots: roots} ->
        if collection == ElixirNexus.QdrantClient.active_collection(), do: roots, else: []

      _ ->
        []
    end
  end

  @doc "Forget the recorded roots (after a purge)."
  @spec clear() :: :ok
  def clear, do: Application.delete_env(:elixir_nexus, @key)
end
