defmodule ElixirNexus.MCPServer.IndexManagement do
  @moduledoc "Collection switching, dirty-file reindexing, and deletion cleanup."

  require Logger

  @graph_wait_ms 90_000

  @doc """
  Switch Qdrant collection to match the project being indexed.

  Collection naming derives from the project name, not the container path.
  For single-project mounts (where project_root == /workspaceN), this avoids
  producing a useless `nexus_workspaceN` and instead names the collection
  after the user-supplied bare name or the host-side basename.
  """
  def ensure_collection_for_project(project_root, display_path \\ nil) do
    project_name = derive_project_name(project_root, display_path)

    collection =
      "nexus_#{project_name}"
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]/, "_")
      |> String.trim_leading("_")
      |> String.trim_trailing("_")
      |> String.slice(0..59)

    current = ElixirNexus.QdrantClient.active_collection()

    if collection != current do
      Logger.info("Switching Qdrant collection: #{current} -> #{collection}")
      ElixirNexus.QdrantClient.switch_collection_force(collection)
      ElixirNexus.Events.broadcast_collection_changed(collection)
    end

    # switch_collection_force doesn't validate existence, and the incremental/partial
    # reindex path (taken whenever DirtyTracker still holds entries from a previously
    # active project) never creates the collection either — only a full reindex does.
    # Without this, reindexing a genuinely new project after any other project has
    # already been indexed in the same server session 404s on every chunk store.
    ElixirNexus.QdrantClient.ensure_collection()
  end

  # Decide what to name a project's Qdrant collection.
  #
  # Priority order for the base name:
  #   1. display_path (the user's bare name like "council-hub") if it's a bare
  #      name (no slash) — that's the user's intent.
  #   2. project_root basename, unless it's a generic /workspace[N] mount root,
  #      in which case fall through.
  #   3. display_path basename (handles full host paths like "/Users/x/foo").
  #   4. project_root basename anyway (last resort).
  #
  # When the project is a subdirectory of a single-project workspace mount
  # (e.g. /workspace4/mcp-server under WORKSPACE_HOST_4=/Users/yourname/council-hub),
  # the parent mount's host basename is prefixed: `council-hub__mcp-server`.
  # This avoids collisions when multiple parent repos contain a similarly-named
  # subproject (council-hub/mcp-server vs elixir-nexus/lib/elixir_nexus/mcp_server.ex).
  defp derive_project_name(project_root, display_path) do
    base = base_name(project_root, display_path)

    case ElixirNexus.MCPServer.PathResolution.parent_mount_basename(project_root) do
      nil -> base
      parent when parent == base -> base
      parent -> "#{parent}__#{base}"
    end
  end

  defp base_name(project_root, display_path) do
    container_basename = Path.basename(project_root)
    looks_generic? = Regex.match?(~r/^workspace[0-9]*$/, container_basename) or container_basename in ["", ".", "_"]

    cond do
      is_binary(display_path) and display_path != "" and not String.contains?(display_path, "/") ->
        display_path

      not looks_generic? ->
        container_basename

      is_binary(display_path) and display_path != "" ->
        Path.basename(display_path)

      true ->
        container_basename
    end
  end

  @doc """
  Bring the index up to date with the disk before a query: reindex files that
  changed and purge files that are gone or no longer in scope.

  Runs once a reindex has recorded its roots for the active collection
  (`ElixirNexus.IndexScope`); the MCP state is not used, because over HTTP every
  request starts with an empty one. Skipped while an index run is in progress.
  Returns `{files_reindexed_or_purged, state}`; the state is passed through.
  """
  def maybe_reindex_dirty(state) do
    # Right after a reindex the graph rebuilds asynchronously (tens of seconds on
    # a large project). Answering meanwhile returns empty results that look like
    # "no callers", so wait for it, bounded.
    if ElixirNexus.GraphCache.await_ready(@graph_wait_ms) == :timeout do
      Logger.warning("Graph still rebuilding after #{@graph_wait_ms}ms; answering from the current graph")
    end

    roots = ElixirNexus.IndexScope.roots()

    if roots == [] or ElixirNexus.Indexer.busy?() do
      {0, state}
    else
      in_scope = ElixirNexus.FileScope.files(roots)
      {reindexed, purged} = sync_with_disk(roots, in_scope)
      {reindexed + purged, state}
    end
  end

  defp sync_with_disk(roots, in_scope) do
    dirty = ElixirNexus.DirtyTracker.dirty_among(in_scope)
    if dirty != [], do: Logger.info("Auto-reindexing #{length(dirty)} dirty file(s) before query")

    Enum.each(dirty, fn path ->
      case ElixirNexus.Indexer.index_file(path) do
        {:ok, _chunks} ->
          ElixirNexus.DirtyTracker.mark_clean(path)

        {:error, reason} ->
          Logger.warning("Auto-reindex failed for #{path}: #{inspect(reason)}")
      end
    end)

    {length(dirty), purge_out_of_scope(roots, in_scope)}
  end

  @doc """
  Purge every indexed file under `roots` that is not in `in_scope`: deleted on
  disk, renamed away, or now excluded by an ignore rule. Files outside every
  root are left alone; a full reindex reconciles those against the collection.
  Returns the number of files purged.
  """
  def purge_out_of_scope(roots, in_scope) do
    scope = MapSet.new(in_scope)
    prefixes = Enum.map(roots, &(String.trim_trailing(&1, "/") <> "/"))

    stale =
      (ElixirNexus.ChunkCache.file_paths() ++ ElixirNexus.DirtyTracker.known_files())
      |> Enum.uniq()
      |> Enum.filter(fn path -> Enum.any?(prefixes, &String.starts_with?(path, &1)) end)
      |> Enum.reject(&MapSet.member?(scope, &1))

    Enum.each(stale, fn path ->
      Logger.info("Removing from index (deleted or out of scope): #{path}")
      ElixirNexus.Indexer.delete_file(path)
    end)

    length(stale)
  end

  @doc """
  Pin the active Qdrant collection into the process dictionary at the start of each
  tool call. QdrantClient.qdrant_state/0 checks this first, so concurrent reindex
  operations cannot swap the collection out from under an in-flight query.
  """
  def capture_collection do
    Process.put(:nexus_collection, ElixirNexus.QdrantClient.active_collection())
  end
end
