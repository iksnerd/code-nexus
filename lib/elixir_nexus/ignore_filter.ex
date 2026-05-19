defmodule ElixirNexus.IgnoreFilter do
  @moduledoc """
  Filters out directories and files that should not be indexed.
  Combines hardcoded defaults with .gitignore and .nexusignore patterns.

  Patterns are tagged by source (`:default`, `:gitignore`, `:nexusignore`) so the
  reindex response can report a per-source breakdown of skipped files.
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

  @type source :: :default | :gitignore | :nexusignore
  @type classification :: :include | {:ignored, source}

  @type t :: %__MODULE__{
          default_dirs: MapSet.t(),
          gitignore_dirs: MapSet.t(),
          nexusignore_dirs: MapSet.t(),
          nexusignore_path_patterns: [String.t()],
          default_file_regexes: [Regex.t()],
          gitignore_file_regexes: [Regex.t()],
          nexusignore_file_regexes: [Regex.t()]
        }

  defstruct default_dirs: MapSet.new(),
            gitignore_dirs: MapSet.new(),
            nexusignore_dirs: MapSet.new(),
            nexusignore_path_patterns: [],
            default_file_regexes: [],
            gitignore_file_regexes: [],
            nexusignore_file_regexes: []

  @doc "Load ignore patterns from defaults, .gitignore, and .nexusignore if present."
  def load(project_root) do
    {git_dirs, git_patterns} = parse_ignore_file(Path.join(project_root, ".gitignore"))

    {nexus_dirs, nexus_path_patterns, nexus_patterns} =
      parse_ignore_file_extended(Path.join(project_root, ".nexusignore"))

    %__MODULE__{
      default_dirs: MapSet.new(@default_dirs),
      gitignore_dirs: MapSet.new(git_dirs),
      nexusignore_dirs: MapSet.new(nexus_dirs),
      nexusignore_path_patterns: nexus_path_patterns,
      default_file_regexes: Enum.flat_map(@default_file_patterns, &compile_glob/1),
      gitignore_file_regexes: Enum.flat_map(git_patterns, &compile_glob/1),
      nexusignore_file_regexes: Enum.flat_map(nexus_patterns, &compile_glob/1)
    }
  end

  @doc """
  Classify a directory by its name and return `:include` or `{:ignored, source}`.

  Source is one of `:default`, `:gitignore`, `:nexusignore`. Dotfiles map to
  `:default` since the leading-dot rule is hardcoded.
  """
  @spec classify_dir(String.t(), t()) :: classification()
  def classify_dir(dir_name, %__MODULE__{} = filter) do
    cond do
      MapSet.member?(filter.nexusignore_dirs, dir_name) -> {:ignored, :nexusignore}
      MapSet.member?(filter.gitignore_dirs, dir_name) -> {:ignored, :gitignore}
      MapSet.member?(filter.default_dirs, dir_name) -> {:ignored, :default}
      String.starts_with?(dir_name, ".") -> {:ignored, :default}
      true -> :include
    end
  end

  @doc """
  Classify a filename by glob patterns and return `:include` or `{:ignored, source}`.
  """
  @spec classify_file(String.t(), t()) :: classification()
  def classify_file(filename, %__MODULE__{} = filter) do
    cond do
      Enum.any?(filter.nexusignore_file_regexes, &Regex.match?(&1, filename)) ->
        {:ignored, :nexusignore}

      Enum.any?(filter.gitignore_file_regexes, &Regex.match?(&1, filename)) ->
        {:ignored, :gitignore}

      Enum.any?(filter.default_file_regexes, &Regex.match?(&1, filename)) ->
        {:ignored, :default}

      true ->
        :include
    end
  end

  @doc """
  Classify a directory by its path relative to the project root.

  Checks nexusignore path patterns (e.g. `docs/internal`) before falling
  back to the basename-only `classify_dir/2` check.  Pass the relative
  path so patterns like `vendor/generated` are matched correctly.
  """
  @spec classify_dir_path(String.t(), t()) :: classification()
  def classify_dir_path(relative_path, %__MODULE__{} = filter) do
    if Enum.any?(filter.nexusignore_path_patterns, fn pattern ->
         relative_path == pattern or String.starts_with?(relative_path, pattern <> "/")
       end) do
      {:ignored, :nexusignore}
    else
      classify_dir(Path.basename(relative_path), filter)
    end
  end

  @doc "Check if a directory name or file path should be ignored."
  def ignored?(path, %__MODULE__{} = filter) do
    basename = Path.basename(path)
    classify_dir(basename, filter) != :include or classify_file(basename, filter) != :include
  end

  @doc "Check if a directory name should be skipped during traversal."
  def ignored_dir?(dir_name, %__MODULE__{} = filter) do
    classify_dir(dir_name, filter) != :include
  end

  @doc "Check if a filename should be skipped based on glob patterns."
  def ignored_file?(filename, %__MODULE__{} = filter) do
    classify_file(filename, filter) != :include
  end

  # Like parse_ignore_file/1 but also returns path patterns (patterns with an
  # internal slash, no globs) as a separate list for root-relative matching.
  defp parse_ignore_file_extended(path) do
    case File.read(path) do
      {:ok, content} ->
        stripped = normalize_ignore_lines(content)
        dirs = stripped |> Enum.filter(&simple_dir_pattern?/1) |> Enum.map(&Path.basename/1)
        path_patterns = Enum.filter(stripped, &path_only_pattern?/1)
        glob_patterns = Enum.filter(stripped, &glob_pattern?/1)
        {dirs, path_patterns, glob_patterns}

      {:error, _} ->
        {[], [], []}
    end
  end

  defp parse_ignore_file(path) do
    case File.read(path) do
      {:ok, content} ->
        stripped = normalize_ignore_lines(content)
        dirs = stripped |> Enum.filter(&simple_dir_pattern?/1) |> Enum.map(&Path.basename/1)
        patterns = Enum.filter(stripped, &glob_pattern?/1)
        {dirs, patterns}

      {:error, _} ->
        {[], []}
    end
  end

  defp normalize_ignore_lines(content) do
    # Strip trailing slashes up front so `build/` and `build` both classify
    # as a simple directory pattern rather than getting silently dropped.
    content
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#") or String.starts_with?(&1, "!")))
    |> Enum.map(&String.trim_trailing(&1, "/"))
  end

  defp simple_dir_pattern?(pattern) do
    not String.contains?(pattern, "*") and
      not String.contains?(pattern, "?") and
      not String.contains?(pattern, "/")
  end

  # Patterns like `docs/internal` — has a slash but no wildcards.
  # Matched root-relative by classify_dir_path/2.
  defp path_only_pattern?(pattern) do
    String.contains?(pattern, "/") and
      not String.contains?(pattern, "*") and
      not String.contains?(pattern, "?")
  end

  defp glob_pattern?(pattern) do
    String.contains?(pattern, "*") or String.contains?(pattern, "?")
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
