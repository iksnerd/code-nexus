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

      # Bare project name — resolve against /workspace
      true ->
        workspace_path = "/workspace/#{path}"

        if File.dir?(workspace_path) do
          {:ok, workspace_path, path}
        else
          {:error, "Project '#{path}' not found in workspace." <> workspace_hint()}
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

  @doc "List project directories available under /workspace."
  def list_workspace_projects do
    case File.ls("/workspace") do
      {:ok, entries} ->
        entries
        |> Enum.filter(&File.dir?(Path.join("/workspace", &1)))
        |> Enum.sort()

      {:error, _} ->
        []
    end
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

  # Translate host filesystem paths to container paths.
  # When running in Docker, WORKSPACE_HOST tells us what host path is mounted at /workspace.
  defp translate_host_path(path) do
    host_prefix = System.get_env("WORKSPACE_HOST", "")

    if host_prefix != "" and String.starts_with?(path, host_prefix) do
      relative = String.trim_leading(path, host_prefix)
      "/workspace" <> relative
    else
      path
    end
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
