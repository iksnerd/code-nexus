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

  # OTP, Phoenix LiveView, and Broadway callback names — dispatched by the framework,
  # never by explicit user call sites. Filtering prevents ~100 false positives on
  # Elixir projects where every GenServer/LiveView/Broadway module looks "dead".
  @elixir_framework_callbacks ~w(
    init terminate code_change
    handle_call handle_cast handle_info handle_continue
    handle_demand handle_subscribe handle_cancel handle_events handle_notify
    handle_message handle_batch handle_failed
    mount render update handle_params handle_event handle_async
    on_mount
  )

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
    {config_root, config} = ElixirNexus.ProjectConfig.current()

    case DataFetching.get_all_entities_cached(:all) do
      {:ok, all_entities} ->
        # Known interface/contract names (TS interfaces, type aliases). A function or const
        # whose return/variable type names one of these is a port implementor — wired through
        # the contract (DI / registry), invisible to the call graph. Lowercased for matching.
        interface_names =
          all_entities
          |> Enum.filter(&(&1.entity["entity_type"] in ["interface", "struct"]))
          |> MapSet.new(&String.downcase(&1.entity["name"] || ""))

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

            # User-declared entry points (.nexus.toml) — framework/DI-wired files whose
            # exports have no in-repo caller (route handlers, sitemap, adapters).
            # Test/spec files are exercised by the test runner, not by app code — their
            # helpers (`daysAgo`, `createAttestation`) are not dead. Skip them wholesale.
            # Go test runner conventions — Test*, Benchmark*, Fuzz*, Example* are
            # called by `go test`, not user code.
            # PascalCase components in convention files are default exports called by the
            # framework (e.g. TorrentsLoading in loading.tsx, RootLayout in layout.tsx).
            # shadcn/ui components in `components/ui/` are library primitives — their
            # exports are intentional API surface, not user-defined call sites.
            # Port implementors — a factory/const typed as a known interface is wired via the
            # contract (DI), so its lack of a direct caller doesn't make it dead.
            entry_point?(file_path, config_root, config) or
              port_implementor?(e.entity, interface_names) or
              test_file?(file_path) or
              (lang == "elixir" and name in @elixir_framework_callbacks) or
              (lang == "go" and Enum.any?(@go_test_prefixes, &String.starts_with?(name, &1))) or
              (js_or_ts?(lang) and
                 (name in @framework_convention_names or
                    (basename in @framework_convention_files and
                       (name == basename or
                          Regex.match?(~r/^[A-Z]/, name) or
                          Regex.match?(~r/^(get|fetch|load|generate)[A-Z]/, name))) or
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

  # True when an entity's `is_a` names a known interface — i.e. it implements a port. The
  # implements edge comes from a return-type or typed-const annotation (class-less TS), so
  # this catches DI-wired adapters that have no static caller.
  defp port_implementor?(entity, interface_names) do
    (entity["is_a"] || [])
    |> Enum.any?(fn t -> MapSet.member?(interface_names, String.downcase(t)) end)
  end

  # A user-declared entry point (.nexus.toml entry_points). Matches the file path made
  # relative to the configured project root against the entry_points globs.
  defp entry_point?(_file, nil, _config), do: false

  defp entry_point?(file_path, config_root, config) do
    rel = Path.relative_to(file_path, config_root)
    ElixirNexus.ProjectConfig.entry_point?(config, rel)
  end

  # Test/spec files across the supported ecosystems — their functions are entry points for
  # the test runner, not dead app code.
  defp test_file?(file_path) do
    Regex.match?(~r/(\.|_)(test|spec)\.[^.\/]+$/, file_path) or
      Regex.match?(~r/_test\.exs?$/, file_path) or
      String.contains?(file_path, "/__tests__/")
  end

  # Matches shadcn/ui's canonical install path. Covers both bare `components/ui/`
  # roots and aliased mounts such as `src/components/ui/` or `apps/web/components/ui/`.
  defp shadcn_ui_export?(file_path) do
    String.contains?(file_path, "/components/ui/")
  end
end
