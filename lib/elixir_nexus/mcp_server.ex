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

  alias ElixirNexus.MCPServer.{IndexManagement, PathResolution, Resources, ResponseFormat}

  @impl true
  def handle_initialize(params, state) do
    # Extract client workspace root from MCP roots (first file:// URI)
    project_root = PathResolution.extract_project_root(params)
    Logger.info("MCP initialized with project root: #{project_root}")

    {:ok,
     %{
       name: "code-nexus",
       version: ElixirNexus.version(),
       description:
         "Code intelligence server — graph-powered semantic search, call graph traversal, " <>
           "transitive impact analysis, and structural coupling for the current project. " <>
           "Supports Elixir, JavaScript/TypeScript/TSX, Python, Go, Rust, and Java. " <>
           "Use instead of Grep when you need to understand relationships between code. " <>
           "Run reindex first (and after code changes). Start with get_graph_stats to orient.",
       capabilities: %{tools: %{}, resources: %{}}
     }, Map.put(state, :project_root, project_root)}
  end

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

  # Resource definitions — expose codebase knowledge as MCP resources.
  # Resource-aware clients read these proactively; others use the load_resources tool fallback.

  defresource "nexus://guide/tools" do
    meta do
      name("CodeNexus Tool Guide")

      description(
        "How to use CodeNexus tools effectively: recommended workflow, when to use each tool, query tips, and common patterns."
      )
    end

    mime_type("text/markdown")
  end

  defresource "nexus://project/overview" do
    meta do
      name("Project Overview")

      description("Quick orientation: language breakdown, file count, function/module counts, and index status.")
    end

    mime_type("text/markdown")
  end

  defresource "nexus://project/architecture" do
    meta do
      name("Project Architecture")

      description("Module hierarchy, key modules by connectivity, and dependency structure.")
    end

    mime_type("text/markdown")
  end

  defresource "nexus://project/hotspots" do
    meta do
      name("Complexity Hotspots")

      description("Most-connected nodes in the call graph (high fan-in/fan-out), critical bottleneck files.")
    end

    mime_type("text/markdown")
  end

  deftool "load_resources" do
    meta do
      name("load_resources")

      description(
        "List or read CodeNexus knowledge resources. Without a URI, lists available resources. " <>
          "With a URI, returns the resource content. Resources provide contextual knowledge " <>
          "(project overview, architecture map, complexity hotspots, tool usage guide) " <>
          "that helps you understand the codebase before making targeted tool calls."
      )
    end

    input_schema(%{
      type: "object",
      properties: %{
        uri: %{
          type: "string",
          description: "Resource URI to read (e.g. 'nexus://guide/tools'). Omit to list all available resources."
        }
      },
      required: []
    })
  end

  # Tool call handlers

  @impl true
  def handle_tool_call("reindex", args, state) do
    project_root = Map.get(state, :project_root, File.cwd!())
    path_arg = Map.get(args, "path")

    case PathResolution.resolve_path(path_arg, project_root) do
      {:ok, index_root, display_path} ->
        dirs = ElixirNexus.IndexingHelpers.detect_indexable_dirs(index_root)

        cond do
          dirs == [] ->
            {:error,
             "No indexable source directories found at '#{display_path}'." <>
               PathResolution.workspace_hint(), state}

          ElixirNexus.Indexer.busy?() ->
            {:error, busy_message(display_path), state}

          true ->
            IndexManagement.ensure_collection_for_project(index_root)
            # Record the project under reindex so a concurrent caller's
            # busy_message/1 can name what is blocking them.
            Application.put_env(:elixir_nexus, :current_project_path, display_path)
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

                result =
                  %{
                    indexed_files: status.indexed_files,
                    total_chunks: status.total_chunks,
                    directories: dirs,
                    project_path: display_path
                  }
                  |> PathResolution.maybe_add_default_path_warning(path_arg, display_path, state)

                Application.put_env(:elixir_nexus, :current_project_path, display_path)

                ResponseFormat.json_reply(
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
    IndexManagement.capture_collection()
    {_reindexed, state} = IndexManagement.maybe_reindex_dirty(state)
    limit = ResponseFormat.to_int(Map.get(args, "limit"), 10)
    {:ok, results} = ElixirNexus.Search.search_code(query, limit)
    ResponseFormat.json_reply(ResponseFormat.compact_results(results), state)
  end

  def handle_tool_call("find_all_callees", %{"entity_name" => name} = args, state) do
    IndexManagement.capture_collection()
    {_reindexed, state} = IndexManagement.maybe_reindex_dirty(state)
    limit = ResponseFormat.to_int(Map.get(args, "limit"), 20)

    case ElixirNexus.Search.find_callees(name, limit) do
      {:ok, results} -> ResponseFormat.json_reply(ResponseFormat.compact_results(results), state)
      {:error, reason} -> {:error, "Callee search failed: #{inspect(reason)}", state}
    end
  end

  def handle_tool_call("analyze_impact", %{"entity_name" => name} = args, state) do
    IndexManagement.capture_collection()
    {_reindexed, state} = IndexManagement.maybe_reindex_dirty(state)
    depth = ResponseFormat.to_int(Map.get(args, "depth"), 3)

    case ElixirNexus.Search.analyze_impact(name, depth) do
      {:ok, result} -> ResponseFormat.json_reply(result, state)
      {:error, reason} -> {:error, "Impact analysis failed: #{inspect(reason)}", state}
    end
  end

  def handle_tool_call("get_community_context", %{"file_path" => path} = args, state) do
    IndexManagement.capture_collection()
    {_reindexed, state} = IndexManagement.maybe_reindex_dirty(state)
    limit = ResponseFormat.to_int(Map.get(args, "limit"), 10)

    case ElixirNexus.Search.get_community_context(path, limit) do
      {:ok, result} -> ResponseFormat.json_reply(result, state)
      {:error, reason} -> {:error, "Community context failed: #{inspect(reason)}", state}
    end
  end

  def handle_tool_call("find_all_callers", %{"entity_name" => name} = args, state) do
    IndexManagement.capture_collection()
    {_reindexed, state} = IndexManagement.maybe_reindex_dirty(state)
    limit = ResponseFormat.to_int(Map.get(args, "limit"), 20)

    case ElixirNexus.Search.find_callers(name, limit) do
      {:ok, results} -> ResponseFormat.json_reply(ResponseFormat.compact_results(results), state)
      {:error, reason} -> {:error, "Caller search failed: #{inspect(reason)}", state}
    end
  end

  def handle_tool_call("get_graph_stats", _args, state) do
    IndexManagement.capture_collection()
    {_reindexed, state} = IndexManagement.maybe_reindex_dirty(state)

    case ElixirNexus.Search.get_graph_stats() do
      {:ok, stats} ->
        project_path =
          Map.get(state, :project_path) ||
            Application.get_env(:elixir_nexus, :current_project_path)

        ResponseFormat.json_reply(Map.put(stats, :project_path, project_path), state)

      {:error, reason} ->
        {:error, "Graph stats failed: #{inspect(reason)}", state}
    end
  end

  def handle_tool_call("find_dead_code", args, state) do
    IndexManagement.capture_collection()
    {_reindexed, state} = IndexManagement.maybe_reindex_dirty(state)

    opts =
      case Map.get(args, "path_prefix") do
        nil -> []
        prefix -> [path_prefix: prefix]
      end

    case ElixirNexus.Search.find_dead_code(opts) do
      {:ok, result} -> ResponseFormat.json_reply(result, state)
      {:error, reason} -> {:error, "Dead code detection failed: #{inspect(reason)}", state}
    end
  end

  def handle_tool_call("find_module_hierarchy", %{"entity_name" => name}, state) do
    IndexManagement.capture_collection()
    {_reindexed, state} = IndexManagement.maybe_reindex_dirty(state)

    case ElixirNexus.Search.find_module_hierarchy(name) do
      {:ok, result} -> ResponseFormat.json_reply(result, state)
      {:error, :not_found} -> {:error, "Module not found: #{name}", state}
      {:error, reason} -> {:error, "Module hierarchy failed: #{inspect(reason)}", state}
    end
  end

  def handle_tool_call("load_resources", args, state) do
    case Map.get(args, "uri") do
      nil ->
        resources = [
          %{
            uri: "nexus://guide/tools",
            name: "CodeNexus Tool Guide",
            description: "How to use each tool, query tips, recommended workflows"
          },
          %{
            uri: "nexus://project/overview",
            name: "Project Overview",
            description: "Language breakdown, file/function/module counts, index status"
          },
          %{
            uri: "nexus://project/architecture",
            name: "Project Architecture",
            description: "Module hierarchy, key modules by connectivity, dependency structure"
          },
          %{
            uri: "nexus://project/hotspots",
            name: "Complexity Hotspots",
            description: "High fan-in/fan-out nodes, bottleneck files, dead code summary"
          }
        ]

        ResponseFormat.json_reply(%{resources: resources}, state)

      uri ->
        case Resources.read_resource_content(uri) do
          {:ok, content} -> {:ok, %{content: [%{type: "text", text: content}]}, state}
          {:error, reason} -> {:error, reason, state}
        end
    end
  end

  def handle_tool_call(name, _args, state) do
    {:error, "Unknown tool: #{name}", state}
  end

  defp busy_message(requested_path) do
    %{indexed_files: indexed, total_chunks: chunks} = ElixirNexus.Indexer.status()
    current_project = Application.get_env(:elixir_nexus, :current_project_path) || "unknown"

    "Cannot reindex '#{requested_path}' — another indexing job is already running for '#{current_project}' " <>
      "(#{indexed} files, #{chunks} chunks indexed so far). " <>
      "Wait for it to complete, then retry. " <>
      "Concurrent reindex of different projects is not supported because each project uses its own Qdrant collection. " <>
      "You can monitor progress at http://localhost:4100."
  end

  # Resource read handler — called by resource-aware MCP clients

  @impl true
  def handle_resource_read(uri, _full_uri, state) do
    case Resources.read_resource_content(uri) do
      {:ok, content} -> {:ok, [text(content)], state}
      {:error, reason} -> {:error, reason, state}
    end
  end
end
