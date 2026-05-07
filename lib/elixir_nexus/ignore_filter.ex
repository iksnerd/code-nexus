defmodule ElixirNexus.IgnoreFilter do
  @moduledoc """
  Filters out directories and files that should not be indexed.
  Combines hardcoded defaults with .gitignore and .nexusignore patterns.
  """

  @default_dirs ~w(
    node_modules .next dist build .expo .turbo coverage
    __generated__ .cache vendor _build deps .elixir_ls
    .git .svn .hg target .venv __pycache__ .mypy_cache
    .pytest_cache .ruff_cache .tox out
  )

  @default_file_patterns ~w(
    *.min.js *.min.css *.map *.lock *.d.ts
  )

  @type t :: %__MODULE__{
          dirs: MapSet.t(),
          file_regexes: [Regex.t()]
        }

  defstruct dirs: MapSet.new(), file_regexes: []

  @doc "Load ignore patterns from defaults, .gitignore, and .nexusignore if present."
  def load(project_root) do
    {git_dirs, git_patterns} = parse_ignore_file(Path.join(project_root, ".gitignore"))
    {nexus_dirs, nexus_patterns} = parse_ignore_file(Path.join(project_root, ".nexusignore"))

    dirs = MapSet.new(@default_dirs ++ git_dirs ++ nexus_dirs)

    file_regexes =
      (@default_file_patterns ++ git_patterns ++ nexus_patterns)
      |> Enum.flat_map(&compile_glob/1)

    %__MODULE__{dirs: dirs, file_regexes: file_regexes}
  end

  @doc "Check if a directory name or file path should be ignored."
  def ignored?(path, %__MODULE__{dirs: dirs, file_regexes: regexes}) do
    basename = Path.basename(path)

    MapSet.member?(dirs, basename) or
      String.starts_with?(basename, ".") or
      Enum.any?(regexes, &Regex.match?(&1, basename))
  end

  @doc "Check if a directory name should be skipped during traversal."
  def ignored_dir?(dir_name, %__MODULE__{dirs: dirs}) do
    MapSet.member?(dirs, dir_name) or String.starts_with?(dir_name, ".")
  end

  @doc "Check if a filename should be skipped based on glob patterns."
  def ignored_file?(filename, %__MODULE__{file_regexes: regexes}) do
    Enum.any?(regexes, &Regex.match?(&1, filename))
  end

  defp parse_ignore_file(path) do
    case File.read(path) do
      {:ok, content} ->
        lines =
          content
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#") or String.starts_with?(&1, "!")))

        dirs =
          lines
          |> Enum.filter(&simple_dir_pattern?/1)
          |> Enum.map(&clean_dir_pattern/1)

        patterns =
          lines
          |> Enum.filter(&glob_pattern?/1)
          |> Enum.map(&String.trim_trailing(&1, "/"))

        {dirs, patterns}

      {:error, _} ->
        {[], []}
    end
  end

  defp simple_dir_pattern?(pattern) do
    not String.contains?(pattern, "*") and
      not String.contains?(pattern, "?") and
      not String.contains?(pattern, "/")
  end

  defp glob_pattern?(pattern) do
    String.contains?(pattern, "*") or String.contains?(pattern, "?")
  end

  defp clean_dir_pattern(pattern) do
    pattern
    |> String.trim_trailing("/")
    |> Path.basename()
  end

  defp compile_glob(pattern) do
    regex_str =
      pattern
      |> String.split("**")
      |> Enum.map(fn part ->
        part
        |> Regex.escape()
        |> String.replace("\\*", "[^/]*")
        |> String.replace("\\?", "[^/]")
      end)
      |> Enum.join(".*")

    case Regex.compile("^#{regex_str}$") do
      {:ok, re} -> [re]
      _ -> []
    end
  end
end
