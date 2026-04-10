defmodule ElixirNexus.MCPServer do
  @moduledoc """
  Model Context Protocol (MCP) server handler for AI agents.

  Exposes tools for semantic code search, callee discovery, and reindexing
  via the MCP protocol.

  Start with stdio transport: `mix mcp`
  Start with HTTP/SSE transport: `mix mcp_http` (port 3001)
  """

  use ExMCP.Server

  # Override get_tools/0 to normalize DSL atom keys to MCP spec camelCase.
  # The ExMCP DSL stores :input_schema, :display_name, :meta — but MCP spec
  # requires "inputSchema" and doesn't use "display_name" or "meta".
  defoverridable get_tools: 0

  def get_tools do
    super()
    |> Map.new(fn {name, tool} ->
      normalized =
        tool
        |> Map.drop([:meta, :display_name])
        |> Enum.into(%{}, fn
          {:input_schema, v} -> {:inputSchema, v}
          {k, v} -> {k, v}
        end)

      {name, normalized}
    end)
  end

  require Logger

  @impl true
  def handle_initialize(params, state) do
    # Extract client workspace root from MCP roots (first file:// URI)
    project_root = extract_project_root(params)
    Logger.info("MCP initialized with project root: #{project_root}")

    {:ok,
     %{
       name: "elixir-nexus",
       version: ElixirNexus.version(),
       description:
         "Code intelligence server — graph-powered semantic search, call graph traversal, " <>
           "transitive impact analysis, and structural coupling for the current project. " <>
           "Supports Elixir, JavaScript/TypeScript/TSX, Python, Go, Rust, and Java. " <>
           "Use instead of Grep when you need to understand relationships between code. " <>
           "Run reindex first (and after code changes). Start with get_graph_stats to orient.",
       capabilities: %{tools: %{}}
     }, Map.put(state, :project_root, project_root)}
  end

  defp extract_project_root(params) do
    Logger.info("MCP initialize params: #{inspect(Map.keys(params))}")

    # Try roots from initialize params (MCP spec)
    with nil <- extract_root_from_list(params["roots"]),
         # Try roots nested under capabilities
         nil <- extract_root_from_list(get_in(params, ["capabilities", "roots"])) do
      File.cwd!()
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

  # Tool definitions

  deftool "search_code" do
    meta do
      name("search_code")

      description(
        "Hybrid semantic + keyword search ranked by TF-IDF similarity, name matching, and call-graph centrality. Requires reindex first. Better than Grep for intent-based queries (e.g. 'error handling in HTTP client'). Returns [{entity, score}] with file_path, entity_type, start_line, end_line, parameters, calls."
      )
    end

    input_schema(%{
      type: "object",
      properties: %{
        query: %{type: "string", description: "Natural language query or code snippet to search for"},
        limit: %{type: "integer", description: "Maximum number of results (default: 10)"}
      },
      required: ["query"]
    })
  end

  deftool "find_all_callees" do
    meta do
      name("find_all_callees")

      description(
        "Find all functions/modules called by a given function — understand dependencies before modifying. Name matching is case-insensitive and supports short names (e.g. 'embed_batch' matches 'ElixirNexus.EmbeddingModel.embed_batch'). Returns resolved entities (file_path, start_line, entity_type) or unresolved names for external calls."
      )
    end

    input_schema(%{
      type: "object",
      properties: %{
        entity_name: %{type: "string", description: "Name of the function to find callees for"},
        limit: %{type: "integer", description: "Maximum number of results (default: 20)"}
      },
      required: ["entity_name"]
    })
  end

  deftool "analyze_impact" do
    meta do
      name("analyze_impact")

      description(
        "Transitive blast radius — walks callers-of-callers up to `depth` levels to find everything affected by a change. Use BEFORE modifying a function to understand what could break (Grep only finds direct references). Returns {root, depth, total_affected, affected_files, impact_tree}."
      )
    end

    input_schema(%{
      type: "object",
      properties: %{
        entity_name: %{type: "string", description: "Name of the function to analyze impact for"},
        depth: %{type: "integer", description: "How many levels of transitive callers to traverse (default: 3)"}
      },
      required: ["entity_name"]
    })
  end

  deftool "get_community_context" do
    meta do
      name("get_community_context")

      description(
        "Find files structurally coupled to a given file via call-graph edges. Use to discover which files should be reviewed together or to understand a file's architectural role. Returns {file, coupled_files} sorted by coupling strength with connection details."
      )
    end

    input_schema(%{
      type: "object",
      properties: %{
        file_path: %{type: "string", description: "Path to the file to find coupled files for"},
        limit: %{type: "integer", description: "Maximum number of coupled files to return (default: 10)"}
      },
      required: ["file_path"]
    })
  end

  deftool "find_all_callers" do
    meta do
      name("find_all_callers")

      description(
        "Find all callers of a function (inverse of find_callees). Use BEFORE renaming or changing a signature. Uses AST-parsed call edges — no false positives from comments or strings. Name matching is case-insensitive and supports short names. Returns caller entities with file_path, entity_type, start_line."
      )
    end

    input_schema(%{
      type: "object",
      properties: %{
        entity_name: %{type: "string", description: "Name of the function to find callers for"},
        limit: %{type: "integer", description: "Maximum number of results (default: 20)"}
      },
      required: ["entity_name"]
    })
  end

  deftool "get_graph_stats" do
    meta do
      name("get_graph_stats")

      description(
        "Structural overview of the indexed codebase — use as a FIRST STEP to orient. Returns node/chunk counts, entity type breakdown, edge counts (calls/imports/contains), language distribution, and top connected modules. No arguments needed."
      )
    end

    input_schema(%{
      type: "object",
      properties: %{},
      required: []
    })
  end

  deftool "find_module_hierarchy" do
    meta do
      name("find_module_hierarchy")

      description(
        "Find a module's parents (uses/implements) and children (contained functions). Use to understand API surface and behavioural contracts (e.g. 'what callbacks does this GenServer implement?'). Returns {name, file_path, parents, children} with resolution status."
      )
    end

    input_schema(%{
      type: "object",
      properties: %{
        entity_name: %{type: "string", description: "Name of the module to find hierarchy for"}
      },
      required: ["entity_name"]
    })
  end

  deftool "find_dead_code" do
    meta do
      name("find_dead_code")

      description(
        "Find exported functions/methods with zero callers — proactively flag unused code. Optionally filter by file path prefix. Returns {dead_functions, total_public, dead_count}."
      )
    end

    input_schema(%{
      type: "object",
      properties: %{
        path_prefix: %{
          type: "string",
          description: "Optional file path prefix to scope the search (e.g. '/workspace/myproject/src')"
        }
      },
      required: []
    })
  end

  deftool "reindex" do
    meta do
      name("reindex")

      description(
        "Build the search index and call graph by parsing source files. MUST run before all other tools, and again after code changes. Auto-detects source dirs (lib/, src/, app/, components/, etc.). Supports Elixir, JS/TS/TSX, Python, Go, Rust, Java. Returns {indexed_files, total_chunks}. On failure, lists available workspace projects."
      )
    end

    input_schema(%{
      type: "object",
      properties: %{
        path: %{
          type: "string",
          description:
            "Project to index. Accepts: bare project name (e.g. 'claude-vision' resolves to /workspace/claude-vision), full host path (e.g. '/Users/you/Documents/project' auto-translated to container path), or container path. Omit to index /app (the CodeNexus repo itself)."
        }
      },
      required: []
    })
  end

  # Tool call handlers

  @impl true
  def handle_tool_call("reindex", args, state) do
    project_root = Map.get(state, :project_root, File.cwd!())

    case resolve_path(Map.get(args, "path"), project_root) do
      {:ok, index_root, display_path} ->
        dirs = ElixirNexus.IndexingHelpers.detect_indexable_dirs(index_root)

        if dirs == [] do
          {:error,
           "No indexable source directories found at '#{display_path}'." <>
             workspace_hint(), state}
        else
          ensure_collection_for_project(index_root)
          Logger.info("Indexing project at #{index_root} (requested: #{display_path}), directories: #{inspect(dirs)}")

          case ElixirNexus.Indexer.index_directories(dirs) do
            {:ok, status} ->
              # File watching is best-effort — don't crash if it fails (e.g. in Docker without inotify)
              try do
                ElixirNexus.FileWatcher.unwatch_all()

                Enum.each(dirs, fn dir ->
                  case ElixirNexus.FileWatcher.watch_directory(dir) do
                    {:ok, _pid} -> :ok
                    {:error, reason} -> Logger.warning("Could not watch #{dir}: #{inspect(reason)}")
                  end
                end)
              rescue
                e -> Logger.warning("File watcher setup failed: #{inspect(e)}")
              end

              result = %{
                indexed_files: status.indexed_files,
                total_chunks: status.total_chunks,
                directories: dirs,
                project_path: display_path
              }

              Application.put_env(:elixir_nexus, :current_project_path, display_path)

              json_reply(
                result,
                state |> Map.put(:indexed_dirs, dirs) |> Map.put(:project_path, display_path)
              )

            {:error, reason} ->
              {:error, "Reindex failed: #{inspect(reason)}", state}
          end
        end

      {:error, message} ->
        {:error, message, state}
    end
  end

  def handle_tool_call("search_code", %{"query" => query} = args, state) do
    {_reindexed, state} = maybe_reindex_dirty(state)
    limit = to_int(Map.get(args, "limit"), 10)
    {:ok, results} = ElixirNexus.Search.search_code(query, limit)
    json_reply(compact_results(results), state)
  end

  def handle_tool_call("find_all_callees", %{"entity_name" => name} = args, state) do
    {_reindexed, state} = maybe_reindex_dirty(state)
    limit = to_int(Map.get(args, "limit"), 20)

    case ElixirNexus.Search.find_callees(name, limit) do
      {:ok, results} -> json_reply(compact_results(results), state)
      {:error, reason} -> {:error, "Callee search failed: #{inspect(reason)}", state}
    end
  end

  def handle_tool_call("analyze_impact", %{"entity_name" => name} = args, state) do
    {_reindexed, state} = maybe_reindex_dirty(state)
    depth = to_int(Map.get(args, "depth"), 3)

    case ElixirNexus.Search.analyze_impact(name, depth) do
      {:ok, result} -> json_reply(result, state)
      {:error, reason} -> {:error, "Impact analysis failed: #{inspect(reason)}", state}
    end
  end

  def handle_tool_call("get_community_context", %{"file_path" => path} = args, state) do
    {_reindexed, state} = maybe_reindex_dirty(state)
    limit = to_int(Map.get(args, "limit"), 10)

    case ElixirNexus.Search.get_community_context(path, limit) do
      {:ok, result} -> json_reply(result, state)
      {:error, reason} -> {:error, "Community context failed: #{inspect(reason)}", state}
    end
  end

  def handle_tool_call("find_all_callers", %{"entity_name" => name} = args, state) do
    {_reindexed, state} = maybe_reindex_dirty(state)
    limit = to_int(Map.get(args, "limit"), 20)

    case ElixirNexus.Search.find_callers(name, limit) do
      {:ok, results} -> json_reply(compact_results(results), state)
      {:error, reason} -> {:error, "Caller search failed: #{inspect(reason)}", state}
    end
  end

  def handle_tool_call("get_graph_stats", _args, state) do
    {_reindexed, state} = maybe_reindex_dirty(state)

    case ElixirNexus.Search.get_graph_stats() do
      {:ok, stats} ->
        project_path =
          Map.get(state, :project_path) ||
            Application.get_env(:elixir_nexus, :current_project_path)

        json_reply(Map.put(stats, :project_path, project_path), state)

      {:error, reason} ->
        {:error, "Graph stats failed: #{inspect(reason)}", state}
    end
  end

  def handle_tool_call("find_dead_code", args, state) do
    {_reindexed, state} = maybe_reindex_dirty(state)

    opts =
      case Map.get(args, "path_prefix") do
        nil -> []
        prefix -> [path_prefix: prefix]
      end

    case ElixirNexus.Search.find_dead_code(opts) do
      {:ok, result} -> json_reply(result, state)
      {:error, reason} -> {:error, "Dead code detection failed: #{inspect(reason)}", state}
    end
  end

  def handle_tool_call("find_module_hierarchy", %{"entity_name" => name}, state) do
    {_reindexed, state} = maybe_reindex_dirty(state)

    case ElixirNexus.Search.find_module_hierarchy(name) do
      {:ok, result} -> json_reply(result, state)
      {:error, :not_found} -> {:error, "Module not found: #{name}", state}
      {:error, reason} -> {:error, "Module hierarchy failed: #{inspect(reason)}", state}
    end
  end

  def handle_tool_call(name, _args, state) do
    {:error, "Unknown tool: #{name}", state}
  end

  # Resolve path argument to a container-local directory.
  # Resolution order:
  #   nil                        → /app (default, project_root)
  #   "/workspace/foo"           → passthrough (already container path)
  #   "/Users/x/Documents/foo"   → translate via WORKSPACE_HOST → /workspace/foo
  #   "foo" (bare name)          → /workspace/foo if it exists, else error with suggestions
  defp resolve_path(nil, project_root), do: {:ok, project_root, project_root}

  defp resolve_path(path, _project_root) when is_binary(path) do
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

  defp list_workspace_projects do
    case File.ls("/workspace") do
      {:ok, entries} ->
        entries
        |> Enum.filter(&File.dir?(Path.join("/workspace", &1)))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  defp workspace_hint do
    case list_workspace_projects() do
      [] -> ""
      projects -> " Available projects: #{Enum.join(projects, ", ")}"
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

  # Switch Qdrant collection to match the project being indexed
  defp ensure_collection_for_project(project_root) do
    collection =
      project_root
      |> Path.basename()
      |> then(&"nexus_#{&1}")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]/, "_")
      |> String.trim_leading("_")
      |> String.slice(0..59)

    current = ElixirNexus.QdrantClient.active_collection()

    if collection != current do
      Logger.info("Switching Qdrant collection: #{current} -> #{collection}")
      GenServer.call(ElixirNexus.QdrantClient, {:switch_collection_force, collection}, 30_000)
      ElixirNexus.Events.broadcast_collection_changed(collection)
    end
  end

  # Auto-reindex dirty files before queries to avoid stale results.
  # Only runs if directories have been indexed (state has :indexed_dirs).
  # Returns {reindexed_count, state} — state unchanged since dirs don't change.
  defp maybe_reindex_dirty(state) do
    dirs = Map.get(state, :indexed_dirs, [])

    if dirs == [] do
      {0, state}
    else
      case ElixirNexus.DirtyTracker.get_dirty_files_recursive(dirs) do
        {:ok, []} ->
          {0, state}

        {:ok, dirty_files} ->
          count = length(dirty_files)
          if count > 0, do: Logger.info("Auto-reindexing #{count} dirty file(s) before query")

          Enum.each(dirty_files, fn path ->
            case ElixirNexus.Indexer.index_file(path) do
              {:ok, _chunks} ->
                ElixirNexus.DirtyTracker.mark_clean(path)

              {:error, reason} ->
                Logger.warning("Auto-reindex failed for #{path}: #{inspect(reason)}")
            end
          end)

          # Clean up files that exist in cache but have been deleted from disk
          deleted_count = cleanup_deleted_files()

          {count + deleted_count, state}

        {:error, _} ->
          {0, state}
      end
    end
  end

  # Remove cached chunks for files that no longer exist on disk.
  # Catches deletions that happened while the server was down.
  defp cleanup_deleted_files do
    deleted_paths =
      try do
        ElixirNexus.ChunkCache.all()
        |> Enum.map(& &1.file_path)
        |> Enum.uniq()
        |> Enum.reject(&File.exists?/1)
      rescue
        _ -> []
      end

    Enum.each(deleted_paths, fn path ->
      Logger.info("Cleaning up deleted file from index: #{path}")
      ElixirNexus.Indexer.delete_file(path)
    end)

    length(deleted_paths)
  end

  # Safe JSON encoding — returns error text instead of crashing on non-serializable values
  defp json_reply(data, state) do
    case Jason.encode(data) do
      {:ok, json} ->
        {:ok, %{content: [%{type: "text", text: json}]}, state}

      {:error, reason} ->
        {:error, "Failed to serialize result: #{inspect(reason)}", state}
    end
  end

  # Compact formatting — strips full source content to save tokens

  defp compact_results(results) when is_list(results) do
    Enum.map(results, &compact_result/1)
  end

  defp compact_result(%{entity: entity} = result) when is_map(entity) do
    compact_entity = compact_entity(entity)

    result
    |> Map.put(:entity, compact_entity)
    |> Map.drop([:vector_score, :keyword_score])
  end

  defp compact_result(%{name: _, resolved: false} = unresolved), do: unresolved

  defp compact_result(other), do: other

  # MCP args come as strings from JSON — coerce to integer for numeric params
  defp to_int(val, _default) when is_integer(val), do: val

  defp to_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end

  defp to_int(_, default), do: default

  defp compact_entity(entity) when is_map(entity) do
    calls = entity["calls"] || []

    %{
      "name" => entity["name"],
      "file_path" => entity["file_path"],
      "entity_type" => entity["entity_type"],
      "start_line" => entity["start_line"],
      "end_line" => entity["end_line"],
      "visibility" => entity["visibility"],
      "parameters" => entity["parameters"] || [],
      "calls" => Enum.take(calls, 10)
    }
  end
end
