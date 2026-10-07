defmodule ElixirNexus.FileScope do
  @moduledoc """
  The one answer to "is this file part of the index?".

  A file is in scope when it is under the indexed root, has an indexable
  extension, and no ignore rule excludes it or any directory above it:
  `.gitignore` (the root's and any nested one, applied to its own subtree),
  `.nexusignore` and the built-in deny list, through `IgnoreFilter`. A pattern
  with a slash at its start or middle is anchored to its ignore file's
  directory, one without matches at any depth, as git does.

  Every path that adds a file to the index goes through here: the full and
  incremental reindex walk (`collect/1`), the dirty-file pass before queries
  (`files/1`), and the file watcher (`in_scope?/2`). The walk and the per-path
  check share `IgnoreFilter`, so they cannot disagree.
  """

  alias ElixirNexus.{IgnoreFilter, IndexingHelpers}

  @type skip_stats :: %{atom() => non_neg_integer()}

  @doc "Every in-scope file under `root`, plus a per-source count of what was skipped."
  @spec collect(String.t()) :: {:ok, [String.t()], skip_stats()} | {:error, term()}
  def collect(root) do
    filter = IgnoreFilter.load(root)

    case File.ls(root) do
      {:ok, entries} ->
        {files, stats} = walk(root, root, entries, filter, [], empty_skip_stats())
        {:ok, files, stats}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Every in-scope file under each root, without duplicates."
  @spec files([String.t()]) :: [String.t()]
  def files(roots) when is_list(roots) do
    roots
    |> Enum.flat_map(fn root ->
      case collect(root) do
        {:ok, files, _stats} -> files
        {:error, _} -> []
      end
    end)
    |> Enum.uniq()
  end

  @doc """
  True when `path` (absolute) would be indexed by a walk of `root`. The file
  need not exist, so a deletion event can be checked too.
  """
  @spec in_scope?(String.t(), String.t()) :: boolean()
  def in_scope?(root, path) do
    root = String.trim_trailing(root, "/")

    with true <- String.starts_with?(path, root <> "/"),
         true <- indexable_extension?(Path.extname(path)) do
      relative = Path.relative_to(path, root)
      segments = Path.split(relative)
      {dir_segments, [file_name]} = Enum.split(segments, -1)

      case included_dirs(root, dir_segments, IgnoreFilter.load(root)) do
        {:ok, filter} -> IgnoreFilter.classify_file_path(relative, file_name, filter) == :include
        :ignored -> false
      end
    else
      _ -> false
    end
  end

  @doc "True when the extension is one the index parses."
  @spec indexable_extension?(String.t()) :: boolean()
  def indexable_extension?(ext) do
    ext in IndexingHelpers.elixir_extensions() or Map.has_key?(IndexingHelpers.polyglot_extensions(), ext)
  end

  @doc "The skip-stats map with every count at zero."
  @spec empty_skip_stats() :: skip_stats()
  def empty_skip_stats do
    %{
      default_deny_dirs: 0,
      gitignore_dirs: 0,
      nexusignore_dirs: 0,
      default_deny_files: 0,
      gitignore_files: 0,
      nexusignore_files: 0,
      unsupported_extension: 0
    }
  end

  @doc "Add two skip-stats maps."
  @spec merge_skip_stats(skip_stats(), skip_stats()) :: skip_stats()
  def merge_skip_stats(a, b), do: Map.merge(a, b, fn _, va, vb -> va + vb end)

  # Walk the directories above the file the way collect/1 walks into them:
  # each must be included, and a .gitignore inside one applies below it.
  defp included_dirs(root, dir_segments, filter) do
    dir_segments
    |> Enum.reduce_while({filter, []}, fn segment, {acc_filter, prefix} ->
      prefix = prefix ++ [segment]
      relative_dir = Path.join(prefix)

      case IgnoreFilter.classify_dir_path(relative_dir, acc_filter) do
        :include -> {:cont, {maybe_merge_gitignore(acc_filter, Path.join(root, relative_dir), relative_dir), prefix}}
        {:ignored, _source} -> {:halt, :ignored}
      end
    end)
    |> case do
      :ignored -> :ignored
      {final_filter, _prefix} -> {:ok, final_filter}
    end
  end

  defp maybe_merge_gitignore(filter, dir, relative_dir) do
    if File.regular?(Path.join(dir, ".gitignore")),
      do: IgnoreFilter.merge_gitignore(filter, dir, relative_dir),
      else: filter
  end

  defp walk(root, base, entries, filter, acc_files, acc_stats) do
    Enum.reduce(entries, {acc_files, acc_stats}, fn entry, {files, stats} ->
      full_path = Path.join(base, entry)
      relative = Path.relative_to(full_path, root)

      cond do
        File.dir?(full_path) ->
          case IgnoreFilter.classify_dir_path(relative, filter) do
            :include ->
              case File.ls(full_path) do
                {:ok, sub_entries} ->
                  sub_filter =
                    if ".gitignore" in sub_entries,
                      do: IgnoreFilter.merge_gitignore(filter, full_path, relative),
                      else: filter

                  walk(root, full_path, sub_entries, sub_filter, files, stats)

                {:error, _} ->
                  {files, stats}
              end

            # A skipped directory counts once per source; its subtree is not
            # walked to estimate file counts, which would defeat skipping it.
            {:ignored, source} ->
              {files, bump(stats, dir_key(source))}
          end

        indexable_extension?(Path.extname(entry)) ->
          case IgnoreFilter.classify_file_path(relative, entry, filter) do
            :include -> {[full_path | files], stats}
            {:ignored, source} -> {files, bump(stats, file_key(source))}
          end

        true ->
          {files, bump(stats, :unsupported_extension)}
      end
    end)
  end

  defp dir_key(:default), do: :default_deny_dirs
  defp dir_key(:gitignore), do: :gitignore_dirs
  defp dir_key(:nexusignore), do: :nexusignore_dirs

  defp file_key(:default), do: :default_deny_files
  defp file_key(:gitignore), do: :gitignore_files
  defp file_key(:nexusignore), do: :nexusignore_files

  defp bump(stats, key), do: Map.update!(stats, key, &(&1 + 1))
end
