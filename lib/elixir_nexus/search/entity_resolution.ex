defmodule ElixirNexus.Search.EntityResolution do
  @moduledoc "Multi-strategy entity lookup, name normalisation, and path alias resolution."

  @definition_types ~w(interface class struct module)

  @doc "Find an entity using exact, file-path, and substring strategies."
  def find_entity_multi_strategy(name, entities) do
    # 1. Exact/qualified match, preferring the real definition (see definition_rank/2)
    # 2. File-path-based: basename matches query
    # 3. Substring: entity name contains query or vice versa
    case Enum.filter(entities, &matches_entity_name?(&1.entity["name"] || "", name)) do
      [] -> nil
      matches -> Enum.min_by(matches, &definition_rank(&1, name))
    end ||
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

  # When several entities share the name: an exact name beats a qualified match
  # (`GPTLanguageModel` over `GPTLanguageModel.hidden`), a non-test file beats a
  # test file (a `type X = import(...)` alias in a test), and a type/module
  # definition beats a variable or function.
  defp definition_rank(e, query) do
    {
      if(String.downcase(e.entity["name"] || "") == String.downcase(query), do: 0, else: 1),
      if(test_file?(e.entity["file_path"] || ""), do: 1, else: 0),
      if(e.entity["entity_type"] in @definition_types, do: 0, else: 1)
    }
  end

  @doc "True for test/spec files across the supported languages."
  def test_file?(path) do
    base = Path.basename(path)

    Regex.match?(~r/[._-](test|spec)\.[a-z]+$/, base) or String.starts_with?(base, "test_") or
      String.contains?(path, ["/test/", "/tests/", "/__tests__/"])
  end

  @doc """
  Resolve names relative to the entity they belong to, instead of project-wide.

  - `:parents` (imports, bases, implemented interfaces): same language family
    only, nearest directory first. A Python class never gets a Go or TSX parent.
  - `:members` (contained members): the entity's own file only, preferring names
    qualified by the entity (`GPTLanguageModel.__init__`). An interface's `get`
    member never resolves to a `GET` route handler elsewhere.

  Anything without an in-scope match is returned unresolved.
  """
  def resolve_names(names, all_entities, context, scope) when scope in [:parents, :members] do
    family = language_family(context.entity["language"])
    context_file = context.entity["file_path"] || ""
    context_name = context.entity["name"] || ""

    in_family =
      Enum.filter(all_entities, fn e ->
        family == :any or language_family(e.entity["language"]) in [family, :any]
      end)

    Enum.map(names, fn name ->
      if scope == :parents and family == "python" and String.starts_with?(name, ".") do
        resolve_python_relative_import(name, context_file, in_family)
      else
        resolve_scoped(name, in_family, scope, context_file, context_name)
      end
    end)
  end

  # `from .attention import X` / `from ..progress import Y` name a module file
  # relative to the importing file's package. Resolve by path; a same-named
  # class somewhere else in the project is not the import.
  defp resolve_python_relative_import(name, context_file, entities) do
    dots = String.length(name) - String.length(String.trim_leading(name, "."))
    module_path = name |> String.trim_leading(".") |> String.replace(".", "/")

    base =
      Enum.reduce(1..dots//1, Path.dirname(context_file), fn
        1, dir -> dir
        _, dir -> Path.dirname(dir)
      end)

    candidates = [Path.join(base, module_path <> ".py"), Path.join([base, module_path, "__init__.py"])]

    case Enum.find(entities, &(&1.entity["file_path"] in candidates)) do
      nil -> %{name: name, resolved: false}
      found -> %{name: name, file_path: found.entity["file_path"], entity_type: "module", resolved: true}
    end
  end

  defp resolve_scoped(name, in_family, scope, context_file, context_name) do
    candidates =
      in_family
      |> Enum.filter(&matches_entity_name?(&1.entity["name"] || "", name))
      |> Enum.reject(&(&1.entity["name"] == context_name and &1.entity["file_path"] == context_file))

    case {best_in_scope(candidates, scope, context_file, context_name), scope} do
      {nil, :parents} -> resolve_by_path_alias(name, in_family) || %{name: name, resolved: false}
      {nil, :members} -> %{name: name, resolved: false}
      {found, _} -> build_resolved_entry(found)
    end
  end

  # Members: only the entity's own file, preferring `Entity.member` over a bare
  # same-named entity in that file.
  defp best_in_scope(candidates, :members, context_file, context_name) do
    qualified = String.downcase("#{context_name}.")

    candidates
    |> Enum.filter(&(&1.entity["file_path"] == context_file))
    |> Enum.min_by(&if(String.starts_with?(String.downcase(&1.entity["name"] || ""), qualified), do: 0, else: 1), fn ->
      nil
    end)
  end

  # Parents: nearest directory first, non-test files before test files.
  defp best_in_scope(candidates, :parents, context_file, _context_name) do
    Enum.min_by(
      candidates,
      &{-shared_dir_depth(&1.entity["file_path"] || "", context_file), test_file?(&1.entity["file_path"] || "")},
      fn -> nil end
    )
  end

  defp language_family(nil), do: :any

  defp language_family(lang) do
    case to_string(lang) do
      "" -> :any
      l when l in ["typescript", "tsx", "javascript", "jsx"] -> :js
      l -> l
    end
  end

  defp shared_dir_depth(a, b) do
    Path.split(Path.dirname(a))
    |> Enum.zip(Path.split(Path.dirname(b)))
    |> Enum.take_while(fn {x, y} -> x == y end)
    |> length()
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
