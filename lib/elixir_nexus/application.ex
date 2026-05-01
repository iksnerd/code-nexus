defmodule ElixirNexus.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # PubSub for LiveView
        {Phoenix.PubSub, name: ElixirNexus.PubSub},

        # File change tracker (for incremental indexing)
        {ElixirNexus.DirtyTracker, []},

        # TF-IDF embedder (sparse vectors for keyword search)
        {ElixirNexus.TFIDFEmbedder, []},

        # Qdrant connection pool
        {ElixirNexus.QdrantClient, []},

        # Process registry (must start before Broadway/IndexingProducer)
        {Registry, keys: :unique, name: ElixirNexus.Registry},

        # ETS table owner (must start before Indexer)
        {ElixirNexus.CacheOwner, []},

        # Code parser and indexer
        {ElixirNexus.Indexer, []},

        # Broadway indexing pipeline
        {ElixirNexus.IndexingPipeline, []},

        # Web server
        {ElixirNexus.Endpoint, []},

        # File watcher for source changes
        {ElixirNexus.FileWatcher, []},

        # Task supervisor for boot-time and on-demand tasks
        {Task.Supervisor, name: ElixirNexus.TaskSupervisor}
      ]
      |> Enum.reject(&is_nil/1)

    # rest_for_one: if a process crashes, all processes started after it restart too.
    # This ensures dependents (Indexer, Pipeline, etc.) restart when their dependencies
    # (Registry, CacheOwner, QdrantClient) crash.
    opts = [strategy: :rest_for_one, name: ElixirNexus.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    # Warm up Ollama so the first real embedding batch doesn't block on cold model load
    if Mix.env() != :test do
      ElixirNexus.EmbeddingModel.warm_up()
    end

    # Start MCP HTTP server if MCP_HTTP_PORT is set (Docker mode)
    if mcp_http_port = System.get_env("MCP_HTTP_PORT") do
      port = String.to_integer(mcp_http_port)

      Task.Supervisor.start_child(ElixirNexus.TaskSupervisor, fn ->
        {:ok, _} = ElixirNexus.MCPServer.start_link(transport: :http, port: port, host: "0.0.0.0", use_sse: true)
        IO.puts("MCP HTTP server listening on port #{port} (with SSE)")
      end)
    end

    # Auto-index on startup — only for local Phoenix server (not MCP, not Docker)
    # In Docker (MCP_HTTP_PORT set), users call reindex explicitly via MCP tool
    mcp_mode? = Application.get_env(:elixir_nexus, :start_mcp_server, false)
    docker_mode? = System.get_env("MCP_HTTP_PORT") != nil

    if Mix.env() != :test and not mcp_mode? and not docker_mode? do
      Task.Supervisor.start_child(ElixirNexus.TaskSupervisor, fn ->
        Process.sleep(1000)
        dirs = ElixirNexus.IndexingHelpers.detect_indexable_dirs(File.cwd!())
        ElixirNexus.Indexer.index_directories(dirs)
        Enum.each(dirs, &ElixirNexus.FileWatcher.watch_directory/1)
      end)
    end

    {:ok, pid}
  end

  @impl true
  def config_change(changed, _new, removed) do
    ElixirNexus.Endpoint.config_change(changed, removed)
    :ok
  end
end
