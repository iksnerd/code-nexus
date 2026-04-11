defmodule ElixirNexus.Search.EntityResolution do
  @moduledoc "Multi-strategy entity lookup, name normalisation, and path alias resolution."

  @doc "Find an entity using exact, file-path, and substring strategies."
  def find_entity_multi_strategy(name, entities) do
    # 1. Exact match (current behavior)
    # 2. File-path-based: basename matches query
    # 3. Substring: entity name contains query or vice versa
    Enum.find(entities, fn e ->
      matches_entity_name?(e.entity["name"] || "", name)
    end) ||
      Enum.find(entities, fn e ->
        file_path_matches_name?(e.entity["file_path"] || "", name)
      end) ||
      Enum.find(entities, fn e ->
        e_name = String.downcase(e.entity["name"] || "")
        q_name = String.downcase(name)

        e_name != "" and q_name != "" and
          (String.contains?(e_name, q_name) or String.contains?(q_name, e_name))
      end)
  end

  @doc "Resolve a list of names to their entity metadata. Falls back to path alias resolution."
  def resolve_names(names, all_entities) do
    Enum.map(names, fn name ->
      case Enum.find(all_entities, fn e ->
             matches_entity_name?(e.entity["name"] || "", name)
           end) do
        nil ->
          resolve_by_path_alias(name, all_entities) || %{name: name, resolved: false}

        found ->
          %{
            name: found.entity["name"],
            file_path: found.entity["file_path"],
            entity_type: found.entity["entity_type"],
            resolved: true
          }
      end
    end)
  end

  @doc "True if `call` matches `entity_name` by exact, qualified, or reverse-qualified comparison."
  def matches_entity_name?(call, entity_name) do
    call_lower = String.downcase(call)
    name_lower = String.downcase(entity_name)

    # Exact match
    # Call is "Module.function" and entity is "function"
    # Call is "function" and entity is "Module.function"
    call_lower == name_lower ||
      String.ends_with?(call_lower, "." <> name_lower) ||
      String.ends_with?(name_lower, "." <> call_lower)
  end

  @doc "True if the import path (e.g. '@/services/foo') refers to the given file path."
  def import_matches_file?(import_path, file_path) do
    # Skip bare package imports (no path separators = npm package, not local file)
    if not String.contains?(import_path, "/") do
      false
    else
      # Normalize: strip @/, ./, ../ prefixes
      normalized =
        import_path
        |> String.replace(~r"^@/", "")
        |> String.replace(~r"^\.\./", "")
        |> String.replace(~r"^\./", "")

      # File path without extension
      file_no_ext = String.replace(file_path, ~r"\.(ts|tsx|js|jsx)$", "")

      # The normalized import path must be a suffix of the file path
      String.ends_with?(file_no_ext, normalized)
    end
  end

  # Attempt to resolve path-aliased imports (e.g. @/components/ui/button) to
  # local entities by stripping the alias prefix and matching against file paths.
  # If tsconfig.json is present, its compilerOptions.paths are applied first for
  # accurate resolution of non-standard aliases (e.g. @/* → src/*).
  defp resolve_by_path_alias(name, all_entities) do
    alias_prefixed? =
      (String.starts_with?(name, "@") or String.starts_with?(name, "~")) and
        String.contains?(name, "/")

    relative_prefixed? =
      String.starts_with?(name, "./") or String.starts_with?(name, "../")

    if alias_prefixed? or relative_prefixed? do
      # Try tsconfig paths first, then fall back to generic @/ stripping
      candidates = tsconfig_resolve(name) ++ [name]

      case Enum.find_value(candidates, fn candidate ->
             Enum.find(all_entities, fn e ->
               import_matches_file?(candidate, e.entity["file_path"] || "")
             end)
           end) do
        nil ->
          # Fallback: match by basename only (e.g. "button" from "@/components/ui/button")
          basename = name |> String.split("/") |> List.last()

          Enum.find(all_entities, fn e ->
            file_path_matches_name?(e.entity["file_path"] || "", basename)
          end)
          |> build_resolved_entry()

        found ->
          build_resolved_entry(found)
      end
    else
      nil
    end
  end

  # Apply tsconfig.json compilerOptions.paths to resolve import aliases.
  # Returns a list of candidate resolved paths (may be empty if no tsconfig or no match).
  defp tsconfig_resolve(import_path) do
    case read_tsconfig_paths() do
      paths when map_size(paths) == 0 ->
        []

      paths ->
        paths
        |> Enum.flat_map(fn {pattern, targets} ->
          apply_tsconfig_pattern(import_path, pattern, targets)
        end)
    end
  end

  # Read compilerOptions.paths from tsconfig.json in the current project.
  # Returns %{"@/*" => ["./src/*"]} or %{} if absent/malformed.
  defp read_tsconfig_paths do
    project_root = Application.get_env(:elixir_nexus, :current_project_path, nil)

    with root when is_binary(root) <- project_root,
         tsconfig_path = Path.join(root, "tsconfig.json"),
         {:ok, content} <- File.read(tsconfig_path),
         {:ok, %{"compilerOptions" => %{"paths" => paths}}} <- Jason.decode(content),
         true <- is_map(paths) do
      paths
    else
      _ -> %{}
    end
  end

  # Apply a single tsconfig path pattern (e.g. "@/*" → ["./src/*"]) to an import path.
  # Returns a list of resolved candidates.
  defp apply_tsconfig_pattern(import_path, pattern, targets) when is_list(targets) do
    if String.ends_with?(pattern, "/*") do
      prefix = String.trim_trailing(pattern, "/*")

      if String.starts_with?(import_path, prefix <> "/") do
        rest = String.trim_leading(import_path, prefix <> "/")

        Enum.map(targets, fn target ->
          target
          |> String.replace("*", rest)
          |> String.replace(~r"^\./", "")
        end)
      else
        []
      end
    else
      if import_path == pattern do
        Enum.map(targets, fn t -> String.replace(t, ~r"^\./", "") end)
      else
        []
      end
    end
  end

  defp apply_tsconfig_pattern(_, _, _), do: []

  defp file_path_matches_name?(file_path, name) when file_path == "" or name == "", do: false

  defp file_path_matches_name?(file_path, name) do
    basename = file_path |> Path.basename() |> Path.rootname()
    normalize_name(basename) == normalize_name(name)
  end

  # Normalize: kebab-case, camelCase, PascalCase → lowercase
  defp normalize_name(name) do
    name
    |> String.replace(~r/[-_]/, "")
    |> String.downcase()
  end

  defp build_resolved_entry(nil), do: nil

  defp build_resolved_entry(entity_result) do
    %{
      name: entity_result.entity["name"],
      file_path: entity_result.entity["file_path"],
      entity_type: entity_result.entity["entity_type"],
      resolved: true
    }
  end
end
