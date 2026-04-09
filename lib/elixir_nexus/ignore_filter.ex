defmodule ElixirNexus.IgnoreFilter do
  @moduledoc """
  Filters out directories and files that should not be indexed.
  Combines hardcoded defaults with .gitignore patterns.
  """

  @default_ignores ~w(
    node_modules .next dist build .expo .turbo coverage
    __generated__ .cache vendor _build deps .elixir_ls
    .git .svn .hg
  )

  @type t :: %__MODULE__{
          patterns: [String.t()],
          dirs: MapSet.t()
        }

  defstruct patterns: [], dirs: MapSet.new()

  @doc "Load ignore patterns from defaults and .gitignore if present."
  def load(project_root) do
    gitignore_dirs = parse_gitignore(Path.join(project_root, ".gitignore"))
    dirs = MapSet.new(@default_ignores ++ gitignore_dirs)
    %__MODULE__{dirs: dirs, patterns: []}
  end

  @doc "Check if a directory name or file path should be ignored."
  def ignored?(path, %__MODULE__{dirs: dirs}) do
    basename = Path.basename(path)
    MapSet.member?(dirs, basename) or String.starts_with?(basename, ".")
  end

  @doc "Check if a directory name should be skipped during traversal."
  def ignored_dir?(dir_name, %__MODULE__{dirs: dirs}) do
    MapSet.member?(dirs, dir_name) or String.starts_with?(dir_name, ".")
  end

  defp parse_gitignore(gitignore_path) do
    case File.read(gitignore_path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
        |> Enum.filter(&simple_dir_pattern?/1)
        |> Enum.map(&clean_dir_pattern/1)

      {:error, _} ->
        []
    end
  end

  # Only handle simple directory name patterns (no globs, no negation)
  defp simple_dir_pattern?(pattern) do
    not String.starts_with?(pattern, "!") and
      not String.contains?(pattern, "*") and
      not String.contains?(pattern, "?")
  end

  defp clean_dir_pattern(pattern) do
    pattern
    |> String.trim_trailing("/")
    |> Path.basename()
  end
end
