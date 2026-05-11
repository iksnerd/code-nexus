defmodule ElixirNexus.Search.DeadCodeDetection do
  @moduledoc "Find exported functions and methods with zero callers (dead code)."

  alias ElixirNexus.Search.DataFetching

  # Exported names that frameworks call via file conventions, not explicit JS call sites.
  # Filtering these prevents false positives in find_dead_code for JS/TS projects.
  @framework_convention_names ~w(
    GET POST PUT PATCH DELETE HEAD OPTIONS
    default generateStaticParams generateMetadata
    loader action headers links handle
  )

  # Go test runner conventions — functions matching these patterns are called by
  # `go test`, not user code. Filtering prevents ~38/49 false positives on Go projects.
  @go_test_prefixes ~w(Test Benchmark Fuzz Example)

  # Next.js / SvelteKit / Remix file-based routing conventions.
  # Default exports from these files are called by the framework, not user code.
  @framework_convention_files ~w(
    page layout loading error not-found template route
    global-error global-not-found sitemap robots manifest
    default
  )

  @doc """
  Find exported functions/methods with zero callers (dead code).
  """
  def find_dead_code(opts \\ []) do
    path_prefix = Keyword.get(opts, :path_prefix)

    case DataFetching.get_all_entities_cached(2000) do
      {:ok, all_entities} ->
        # Build reverse call index (calls only, not imports).
        # Also build a suffix set: for dotted calls like "utils.format", store the short
        # name "format" so qualified-name lookup is O(1) instead of O(n) per entity.
        {call_index, call_suffix_set} =
          Enum.reduce(all_entities, {%{}, MapSet.new()}, fn e, {index, suffixes} ->
            Enum.reduce(e.entity["calls"] || [], {index, suffixes}, fn call, {idx, sfx} ->
              key = String.downcase(call)
              idx = Map.put(idx, key, true)

              sfx =
                case String.split(key, ".") do
                  [_mod, short] -> MapSet.put(sfx, short)
                  [_mod, _mid, short] -> MapSet.put(sfx, short)
                  _ -> sfx
                end

              {idx, sfx}
            end)
          end)

        # Find public functions/methods with zero callers
        dead =
          all_entities
          |> Enum.filter(fn e ->
            type = e.entity["entity_type"]
            vis = e.entity["visibility"]
            type in ["function", "method"] and vis in ["public", nil]
          end)
          |> then(fn entities ->
            if path_prefix do
              Enum.filter(entities, &String.starts_with?(&1.entity["file_path"] || "", path_prefix))
            else
              entities
            end
          end)
          |> Enum.reject(fn e ->
            lang = e.entity["language"] || ""
            name = e.entity["name"] || ""
            file_path = e.entity["file_path"] || ""
            basename = file_path |> Path.basename() |> String.replace(~r/\.[^.]+$/, "")

            # Go test runner conventions — Test*, Benchmark*, Fuzz*, Example* are
            # called by `go test`, not user code.
            # PascalCase components in convention files are default exports called by the
            # framework (e.g. TorrentsLoading in loading.tsx, RootLayout in layout.tsx).
            # shadcn/ui components in `components/ui/` are library primitives — their
            # exports are intentional API surface, not user-defined call sites.
            (lang == "go" and Enum.any?(@go_test_prefixes, &String.starts_with?(name, &1))) or
              (js_or_ts?(lang) and
                 (name in @framework_convention_names or
                    (Regex.match?(~r/^[A-Z]/, name) and basename in @framework_convention_files) or
                    shadcn_ui_export?(file_path)))
          end)
          |> Enum.filter(fn e ->
            name = e.entity["name"] || ""
            name_lower = String.downcase(name)
            # No entity calls this function (exact match or qualified suffix match)
            not Map.has_key?(call_index, name_lower) and
              not MapSet.member?(call_suffix_set, name_lower)
          end)
          |> Enum.map(fn e ->
            %{
              name: e.entity["name"],
              file_path: e.entity["file_path"],
              entity_type: e.entity["entity_type"],
              start_line: e.entity["start_line"]
            }
          end)

        total_public =
          all_entities
          |> Enum.count(fn e ->
            type = e.entity["entity_type"]
            vis = e.entity["visibility"]
            type in ["function", "method"] and vis in ["public", nil]
          end)

        has_js_ts =
          Enum.any?(all_entities, fn e -> js_or_ts?(e.entity["language"] || "") end)

        warning =
          if has_js_ts do
            "Results may include false positives for framework-exported functions " <>
              "(Next.js/SvelteKit/Remix route handlers and page components are called " <>
              "by the framework via file conventions, not explicit JS call sites). " <>
              "Known convention names (GET, POST, default, etc.) are pre-filtered."
          end

        {:ok,
         %{
           dead_functions: dead,
           total_public: total_public,
           dead_count: length(dead),
           warning: warning
         }}

      error ->
        error
    end
  end

  defp js_or_ts?(lang) do
    String.contains?(lang, "javascript") or String.contains?(lang, "typescript") or
      lang in ["tsx", "jsx"]
  end

  # Matches shadcn/ui's canonical install path. Covers both bare `components/ui/`
  # roots and aliased mounts such as `src/components/ui/` or `apps/web/components/ui/`.
  defp shadcn_ui_export?(file_path) do
    String.contains?(file_path, "/components/ui/")
  end
end
