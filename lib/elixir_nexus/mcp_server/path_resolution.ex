defmodule ElixirNexus.MCPServer.PathResolution do
  @moduledoc "Resolve MCP path arguments to container-local directories."

  require Logger

  @doc """
  Extract the project root from MCP initialize params.
  Falls back to File.cwd! if no roots are provided.
  """
  def extract_project_root(params) do
    Logger.info("MCP initialize params: #{inspect(Map.keys(params))}")

    # Try roots from initialize params (MCP spec)
    with nil <- extract_root_from_list(params["roots"]),
         # Try roots nested under capabilities
         nil <- extract_root_from_list(get_in(params, ["capabilities", "roots"])) do
      File.cwd!()
    end
  end

  @doc """
  Resolve path argument to a container-local directory.

  Resolution order:
    nil                        → /app (default, project_root)
    "/workspace/foo"           → passthrough (already container path)
    "/Users/x/Documents/foo"   → translate via WORKSPACE_HOST → /workspace/foo
    "foo" (bare name)          → /workspace/foo if it exists, else error with suggestions
  """
  def resolve_path(nil, project_root) do
    # When workspace projects are available, require an explicit path.
    # Omitting it would silently index the ElixirNexus repo itself (/app),
    # which is almost never what users want.
    case list_workspace_projects() do
      [] ->
        {:ok, project_root, project_root}

      projects ->
        {:error,
         "No project path specified. Omitting 'path' would index the ElixirNexus repo itself, not your project. " <>
           "Specify a project name or path. Available workspace projects: #{Enum.join(projects, ", ")}"}
    end
  end

  def resolve_path(path, _project_root) when is_binary(path) do
    cond do
      # Absolute path — translate host paths, then validate
      String.starts_with?(path, "/") ->
        container_path = translate_host_path(path)
        root = find_project_root(container_path)

        if File.dir?(root) do
          {:ok, root, path}
        else
          {:error, "Path '#{path}' not found (resolved to '#{root}')." <> workspace_hint()}
        end

      # Bare project name — resolve against any active workspace mount
      true ->
        case resolve_bare_name(path) do
          nil -> {:error, "Project '#{path}' not found in workspace." <> workspace_hint()}
          workspace_path -> {:ok, workspace_path, path}
        end
    end
  end

  @doc "Return a hint listing available workspace projects, or empty string if none."
  def workspace_hint do
    case list_workspace_projects() do
      [] -> ""
      projects -> " Available projects: #{Enum.join(projects, ", ")}"
    end
  end

  @doc """
  List project directories available across all active workspace mounts.
  Includes single-project mounts (where the mount itself is the project) under
  their host basename, in addition to direct children of multi-project mounts.
  """
  def list_workspace_projects do
    workspace_mounts()
    |> Enum.flat_map(fn {mount, host_prefix} ->
      children =
        case File.ls(mount) do
          {:ok, entries} -> Enum.filter(entries, &File.dir?(Path.join(mount, &1)))
          {:error, _} -> []
        end

      # Single-project mount: include the mount's own basename if it looks
      # like a project root (has source dirs at top level OR a README/Makefile/
      # docker-compose.yml at the root). Multi-component repos like council-hub
      # match via the second condition.
      self_name =
        if host_prefix != "" and looks_like_project_root?(mount) do
          [Path.basename(host_prefix)]
        else
          []
        end

      children ++ self_name
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp looks_like_project_root?(path) do
    source_dirs = ~w(lib src app pages components packages services)

    project_markers =
      ~w(README.md README Makefile Dockerfile docker-compose.yml mix.exs package.json Cargo.toml go.mod pyproject.toml)

    Enum.any?(source_dirs, fn dir -> File.dir?(Path.join(path, dir)) end) or
      Enum.any?(project_markers, fn marker -> File.regular?(Path.join(path, marker)) end)
  end

  @doc """
  Adds a warning key to the reindex result when no path was given and no project
  was previously indexed. Prevents silent "why am I seeing Elixir results?" confusion.
  """
  def maybe_add_default_path_warning(result, path_arg, display_path, state) do
    if is_nil(path_arg) and not Map.has_key?(state, :indexed_dirs) do
      Map.put(
        result,
        :warning,
        "No 'path' argument given — indexed '#{display_path}' (the CodeNexus repo itself). " <>
          "Pass a 'path' to index your own project instead."
      )
    else
      result
    end
  end

  # Returns all active workspace mount configs: [{container_path, host_prefix}, ...]
  # Primary slot is always active when the dir exists.
  # Optional slots 2/3 require WORKSPACE_HOST_N to be set (non-empty), so that
  # an unset WORKSPACE_2 mounting "." doesn't pollute project listing.
  defp workspace_mounts do
    primary = [{"/workspace", System.get_env("WORKSPACE_HOST", "")}]

    optional =
      [
        {"/workspace2", System.get_env("WORKSPACE_HOST_2", "")},
        {"/workspace3", System.get_env("WORKSPACE_HOST_3", "")},
        {"/workspace4", System.get_env("WORKSPACE_HOST_4", "")},
        {"/workspace5", System.get_env("WORKSPACE_HOST_5", "")}
      ]
      |> Enum.filter(fn {mount, host} -> host != "" and File.dir?(mount) end)

    (primary ++ optional)
    |> Enum.filter(fn {mount, _host} -> File.dir?(mount) end)
  end

  @doc """
  Return the host basename of the single-project workspace mount that contains
  `container_path`, or nil if no such mount exists.

  Used by IndexManagement.derive_project_name/2 to prefix collection names with
  the parent project when reindexing a subproject. Example: `/workspace4/mcp-server`
  with `WORKSPACE_HOST_4=/Users/yourname/council-hub` → returns `"council-hub"`, so
  the collection becomes `nexus_council_hub__mcp_server` instead of the ambiguous
  `nexus_mcp_server`.

  Returns nil for multi-project mounts (e.g. `/workspace/foo` where /workspace is
  a parent of many projects), since the project name alone is unambiguous there.
  """
  def parent_mount_basename(container_path) do
    Enum.find_value(workspace_mounts(), fn {mount, host_prefix} ->
      cond do
        host_prefix == "" ->
          nil

        # Strict subpath of mount AND the mount itself is a project (not just
        # a parent dir of projects). Distinguishes single-project mounts like
        # WORKSPACE_HOST=/Users/yourname/council-hub (parent for prefixing) from
        # multi-project mounts like WORKSPACE_HOST=/Users/yourname/www (not).
        container_path != mount and
          String.starts_with?(container_path, mount <> "/") and
            looks_like_project_root?(mount) ->
          Path.basename(host_prefix)

        true ->
          nil
      end
    end)
  end

  defp resolve_bare_name(name) do
    Enum.find_value(workspace_mounts(), fn {mount, host_prefix} ->
      cond do
        # Mount contains a child dir matching the name: /workspace2/llm-memory
        File.dir?(Path.join(mount, name)) ->
          Path.join(mount, name)

        # Mount itself is a single-project mount whose host basename matches:
        # WORKSPACE_HOST_4=/Users/yourname/council-hub → bare "council-hub" resolves to /workspace4
        host_prefix != "" and Path.basename(host_prefix) == name and File.dir?(mount) ->
          mount

        true ->
          nil
      end
    end)
  end

  # Translate host filesystem paths to container paths using any active workspace mount.
  defp translate_host_path(path) do
    Enum.find_value(workspace_mounts(), path, fn {mount, host_prefix} ->
      if host_prefix != "" and String.starts_with?(path, host_prefix) do
        Path.join(mount, String.replace_prefix(path, host_prefix, ""))
      end
    end)
  end

  defp find_project_root(path) do
    basename = Path.basename(path)

    source_dirs =
      ~w(lib src app pages components utils packages services infrastructure repositories core hooks api modules controllers models views)

    if basename in source_dirs and File.dir?(path) do
      Path.dirname(path)
    else
      path
    end
  end

  defp extract_root_from_list(roots) when is_list(roots) do
    Enum.find_value(roots, fn
      %{"uri" => "file://" <> path} -> path
      %{"uri" => path} -> path
      _ -> nil
    end)
  end

  defp extract_root_from_list(_), do: nil
end
