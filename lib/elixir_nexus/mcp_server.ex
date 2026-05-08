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
        "Hybrid semantic + keyword search ranked by TF-IDF similarity, name matching, and call-graph centrality. Requires reindex first — returns an empty list if nothing is indexed in the current Qdrant collection. Better than Grep for intent-based queries (e.g. 'error handling in HTTP client'). Returns [{entity, score}] with file_path, entity_type, start_line, end_line, parameters, calls."
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
        "Find all functions/modules called by a given function — understand dependencies before modifying. Requires reindex first; returns an empty list if the entity isn't in the indexed call graph. Name matching is case-insensitive and supports short names (e.g. 'embed_batch' matches 'ElixirNexus.EmbeddingModel.embed_batch'). Returns resolved entities (file_path, start_line, entity_type) or unresolved names for external calls."
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
        "Transitive blast radius — walks callers-of-callers up to `depth` levels to find everything affected by a change. Use BEFORE modifying a function to understand what could break (Grep only finds direct references). Requires reindex first; returns an empty tree if the entity isn't in the indexed call graph. Returns {root, depth, total_affected, affected_files, impact_tree}."
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
        "Answer 'what other files should I read or edit alongside this one?' — finds files that call into or are called from the given file via AST call-graph edges. Use when starting work in an unfamiliar file to surface related context. Requires reindex first; returns an empty coupled_files list if the file isn't in the indexed graph. Returns {file, coupled_files} sorted by coupling strength with connection details."
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
        "Find all callers of a function (inverse of find_callees). Use BEFORE renaming or changing a signature. Requires reindex first; returns an empty list if the entity isn't in the indexed call graph. Uses AST-parsed call edges — no false positives from comments or strings. Name matching is case-insensitive and supports short names. Returns caller entities with file_path, entity_type, start_line."
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
        "Structural overview of the indexed codebase — use as a FIRST STEP to orient. Returns node/chunk counts, entity type breakdown, edge counts (calls/imports/contains), language distribution, top connected modules, and project_path. Returns zeros / empty distributions when nothing is indexed yet (run reindex first). No arguments needed."
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
        "Find a module's parents (uses/implements) and children (contained functions). Use to understand API surface and behavioural contracts (e.g. 'what callbacks does this GenServer implement?'). Requires reindex first; returns empty parents/children if the module isn't in the indexed graph. Returns {name, file_path, parents, children} with resolution status."
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
        "Find exported functions/methods with zero callers — use before cleanup PRs or when deleting a module to confirm nothing depends on it. Requires a fully reindexed call graph; returns an empty dead_functions list if nothing is indexed. False positives are possible for entry points (CLI mains, route handlers) called from outside the indexed code — verify with analyze_impact before deleting. Optionally filter by file path prefix. Returns {dead_functions, total_public, dead_count}."
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
        "Build the search index and call graph by parsing source files. MUST run before all other tools, and again after code changes. Indexes the project root inclusively, applying .gitignore + .nexusignore + the built-in deny-list. Supports Elixir, JS/TS/TSX, Python, Go, Rust, Java, Ruby. Returns {indexed_files, total_chunks, languages: [{lang, file_count}], skipped: {default_deny_dirs, gitignore_dirs, nexusignore_dirs, default_deny_files, gitignore_files, nexusignore_files, unsupported_extension}}. The skipped breakdown lets you debug ignore rules — if your .nexusignore patterns aren't excluding what you expect, the counts will show it. On failure, lists available workspace projects."
      )
    end

    input_schema(%{
      type: "object",
      properties: %{
        path: %{
          type: "string",
          description:
            "Project to index. Accepts: bare project name (e.g. 'claude-vision' resolves to /workspace/claude-vision), full host path (e.g. '/Users/you/Documents/project' auto-translated to container path), or container path. Required when a WORKSPACE is mounted."
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

  defresource "nexus://skills/index" do
    meta do
      name("Skills Index")
      description("List of all bundled skills (domain-specific guidance docs) with their URIs.")
    end

    mime_type("text/markdown")
  end

  # One MCP resource per bundled skill so clients with resource support can
  # discover and read them directly. The set is enumerated at compile time
  # by ElixirNexus.MCPServer.Resources from `.agents/skills/`.
  for {skill, desc} <- Resources.skill_index() do
    defresource "nexus://skill/#{skill}" do
      meta do
        name("Skill: #{skill}")
        description(desc)
      end

      mime_type("text/markdown")
    end
  end

  deftool "get_status" do
    meta do
      name("get_status")

      description(
        "Returns current server status: indexed project path, Qdrant health, Ollama connectivity, " <>
          "file/chunk counts, available workspace projects, and active collections. " <>
          "Use to verify what is indexed before querying, or to diagnose setup issues."
      )
    end

    input_schema(%{
      type: "object",
      properties: %{},
      required: []
    })
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
            IndexManagement.ensure_collection_for_project(index_root, display_path)
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
                    languages: Map.get(status, :languages, []),
                    skipped: Map.get(status, :skipped, %{}),
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

  def handle_tool_call("get_status", _args, state) do
    current_project = current_project_path(state)

    qdrant =
      case ElixirNexus.QdrantClient.health_check() do
        {:ok, _} -> "ok"
        {:error, reason} -> "unreachable: #{inspect(reason)}"
      end

    collections =
      case ElixirNexus.QdrantClient.list_collections() do
        {:ok, names} -> names
        {:error, _} -> []
      end

    status = %{
      indexed: Map.has_key?(state, :indexed_dirs) or ElixirNexus.ChunkCache.count() > 0,
      current_project: current_project,
      file_count: ElixirNexus.ChunkCache.count(),
      qdrant: qdrant,
      collections: collections,
      ollama_url: ElixirNexus.EmbeddingModel.base_url(),
      embedding_model: ElixirNexus.EmbeddingModel.model_name(),
      workspace_projects: PathResolution.list_workspace_projects()
    }

    ResponseFormat.json_reply(status, state)
  end

  def handle_tool_call("get_graph_stats", _args, state) do
    IndexManagement.capture_collection()
    {_reindexed, state} = IndexManagement.maybe_reindex_dirty(state)

    case ElixirNexus.Search.get_graph_stats() do
      {:ok, stats} ->
        ResponseFormat.json_reply(Map.put(stats, :project_path, current_project_path(state)), state)

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
        core = [
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
          },
          %{
            uri: "nexus://skills/index",
            name: "Skills Index",
            description: "List of all bundled skills with their nexus://skill/<name> URIs"
          }
        ]

        skill_resources =
          Resources.skill_index()
          |> Enum.sort()
          |> Enum.map(fn {name, desc} ->
            %{uri: "nexus://skill/#{name}", name: "Skill: #{name}", description: desc}
          end)

        ResponseFormat.json_reply(%{resources: core ++ skill_resources}, state)

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

  # Resolve the current project path with three fallbacks so get_graph_stats
  # and get_status never return null when *something* is indexed:
  #   1. session-scoped state (set by the most recent reindex in this MCP session)
  #   2. application env (set by reindex across sessions in the same BEAM)
  #   3. derived from the active Qdrant collection name (covers cold sessions)
  defp current_project_path(state) do
    Map.get(state, :project_path) ||
      Application.get_env(:elixir_nexus, :current_project_path) ||
      project_from_active_collection()
  end

  defp project_from_active_collection do
    case ElixirNexus.QdrantClient.active_collection() do
      nil -> nil
      "" -> nil
      "nexus_" <> rest -> rest
      other -> other
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
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
