defmodule ElixirNexus.Search.GraphStatsTest do
  use ExUnit.Case, async: false

  alias ElixirNexus.Search.Queries
  alias ElixirNexus.ChunkCache
  alias ElixirNexus.GraphCache

  @test_chunks [
    %{
      id: "chunk_1",
      file_path: "/app/lib/server.ex",
      entity_type: :module,
      name: "Server",
      content: "defmodule Server do\nend",
      start_line: 1,
      end_line: 10,
      module_path: "Server",
      visibility: :public,
      parameters: [],
      calls: ["GenServer.start_link", "handle_call"],
      is_a: ["GenServer"],
      contains: ["Server.handle_call", "Server.init"],
      language: :elixir
    },
    %{
      id: "chunk_2",
      file_path: "/app/lib/server.ex",
      entity_type: :function,
      name: "Server.handle_call",
      content: "def handle_call(:ping, _from, state) do\n  {:reply, :pong, state}\nend",
      start_line: 5,
      end_line: 7,
      module_path: "Server",
      visibility: :public,
      parameters: ["msg", "_from", "state"],
      calls: ["Logger.info"],
      is_a: [],
      contains: [],
      language: :elixir
    },
    %{
      id: "chunk_3",
      file_path: "/app/lib/client.ex",
      entity_type: :function,
      name: "Client.call_server",
      content: "def call_server(msg) do\n  Server.handle_call(msg)\nend",
      start_line: 1,
      end_line: 3,
      module_path: "Client",
      visibility: :public,
      parameters: ["msg"],
      calls: ["Server.handle_call"],
      is_a: [],
      contains: [],
      language: :elixir
    },
    %{
      id: "chunk_4",
      file_path: "/app/lib/router.ex",
      entity_type: :function,
      name: "Router.dispatch",
      content: "def dispatch(req) do\n  Client.call_server(req)\nend",
      start_line: 1,
      end_line: 3,
      module_path: "Router",
      visibility: :public,
      parameters: ["req"],
      calls: ["Client.call_server"],
      is_a: [],
      contains: [],
      language: :elixir
    },
    %{
      id: "chunk_5",
      file_path: "/app/lib/utils.ex",
      entity_type: :function,
      name: "Utils.format",
      content: "def format(data), do: data",
      start_line: 1,
      end_line: 1,
      module_path: "Utils",
      visibility: :public,
      parameters: ["data"],
      calls: [],
      is_a: [],
      contains: [],
      language: :elixir
    }
  ]

  setup do
    # Populate ETS caches with test data
    ChunkCache.clear()
    GraphCache.clear()

    ChunkCache.insert_many(@test_chunks)
    GraphCache.rebuild_from_chunks(@test_chunks)

    on_exit(fn ->
      ChunkCache.clear()
      GraphCache.clear()
    end)

    :ok
  end

  describe "get_graph_stats/0" do
    test "returns stats with expected keys" do
      {:ok, stats} = Queries.get_graph_stats()

      assert is_integer(stats.total_nodes)
      assert is_integer(stats.total_chunks)
      assert is_list(stats.entity_types)
      assert is_map(stats.edge_counts)
      assert is_list(stats.top_connected)
      assert is_list(stats.languages)
    end

    test "entity_types breakdown is correct" do
      {:ok, stats} = Queries.get_graph_stats()

      type_names = Enum.map(stats.entity_types, & &1.type)
      assert Enum.any?(type_names, &(&1 in ["function", "module"]))
    end

    test "edge counts are non-negative" do
      {:ok, stats} = Queries.get_graph_stats()

      assert stats.edge_counts.calls >= 0
      assert stats.edge_counts.imports >= 0
      assert stats.edge_counts.contains >= 0
    end

    test "top_connected returns up to 10 entries" do
      {:ok, stats} = Queries.get_graph_stats()
      assert length(stats.top_connected) <= 10
    end

    test "languages breakdown includes elixir" do
      {:ok, stats} = Queries.get_graph_stats()

      langs = Enum.map(stats.languages, & &1.language)
      assert "elixir" in langs
    end
  end

  describe "get_graph_stats/0 - empty caches" do
    test "returns zeros after clearing caches" do
      ChunkCache.clear()
      GraphCache.clear()

      {:ok, stats} = Queries.get_graph_stats()
      assert stats.total_nodes == 0
      assert stats.total_chunks == 0
    end
  end

  describe "get_graph_stats layers" do
    setup do
      # Mirror production: reindex always stores {project_root, config}, so layers are
      # classified on root-relative paths. Without this, the "/app" prefix would itself
      # match the presentation "app" alias.
      prev = Application.get_env(:elixir_nexus, :project_config)

      Application.put_env(
        :elixir_nexus,
        :project_config,
        {"/app", %ElixirNexus.ProjectConfig{}}
      )

      on_exit(fn ->
        if prev,
          do: Application.put_env(:elixir_nexus, :project_config, prev),
          else: Application.delete_env(:elixir_nexus, :project_config)
      end)

      :ok
    end

    test "returns a layers breakdown" do
      {:ok, stats} = Queries.get_graph_stats()

      assert Map.has_key?(stats, :layers)
      assert is_list(stats.layers)
      # Fixtures live under /app/lib/* → root-relative "lib/*" → the "lib" layer.
      assert Enum.any?(stats.layers, &(&1.layer == "lib"))
    end
  end

  describe "get_graph_stats critical_files" do
    test "returns critical_files field" do
      {:ok, stats} = Queries.get_graph_stats()

      assert Map.has_key?(stats, :critical_files)
      assert is_list(stats.critical_files)
    end
  end

  describe "get_graph_stats/0 - critical_files with connected graph" do
    test "critical_files returns entries when graph has connected nodes" do
      # Build a denser graph: A → B → C → D → E, all passing through B and C
      chain = [
        %{
          id: "c_a",
          file_path: "/app/lib/a.ex",
          entity_type: :function,
          name: "A.run",
          content: "",
          start_line: 1,
          end_line: 1,
          module_path: "A",
          visibility: :public,
          parameters: [],
          calls: ["B.run"],
          is_a: [],
          contains: [],
          language: :elixir
        },
        %{
          id: "c_b",
          file_path: "/app/lib/b.ex",
          entity_type: :function,
          name: "B.run",
          content: "",
          start_line: 1,
          end_line: 1,
          module_path: "B",
          visibility: :public,
          parameters: [],
          calls: ["C.run"],
          is_a: [],
          contains: [],
          language: :elixir
        },
        %{
          id: "c_c",
          file_path: "/app/lib/c.ex",
          entity_type: :function,
          name: "C.run",
          content: "",
          start_line: 1,
          end_line: 1,
          module_path: "C",
          visibility: :public,
          parameters: [],
          calls: ["D.run"],
          is_a: [],
          contains: [],
          language: :elixir
        },
        %{
          id: "c_d",
          file_path: "/app/lib/d.ex",
          entity_type: :function,
          name: "D.run",
          content: "",
          start_line: 1,
          end_line: 1,
          module_path: "D",
          visibility: :public,
          parameters: [],
          calls: ["E.run"],
          is_a: [],
          contains: [],
          language: :elixir
        },
        %{
          id: "c_e",
          file_path: "/app/lib/e.ex",
          entity_type: :function,
          name: "E.run",
          content: "",
          start_line: 1,
          end_line: 1,
          module_path: "E",
          visibility: :public,
          parameters: [],
          calls: [],
          is_a: [],
          contains: [],
          language: :elixir
        }
      ]

      ChunkCache.clear()
      GraphCache.clear()
      ChunkCache.insert_many(chain)
      GraphCache.rebuild_from_chunks(chain)

      {:ok, stats} = Queries.get_graph_stats()

      assert is_list(stats.critical_files)
      # B, C, D sit on the only path A→E so they must have centrality > 0
      assert length(stats.critical_files) > 0,
             "Expected critical_files to be non-empty for a linear chain graph"

      Enum.each(stats.critical_files, fn cf ->
        assert cf.file_path != nil, "critical_files entry has nil file_path"
        assert is_number(cf.centrality_score)
      end)
    end
  end

  describe "get_graph_stats/0 - framework noise filtering" do
    test "excludes known framework utility names from top_connected" do
      noise_chunks =
        ~w(cn clsx Comp Slot twMerge)
        |> Enum.with_index()
        |> Enum.map(fn {name, i} ->
          callers =
            1..50
            |> Enum.map(fn j ->
              %{
                id: "caller_#{name}_#{j}",
                file_path: "/app/components/c#{j}.tsx",
                entity_type: :function,
                name: "Component#{j}.render",
                content: "",
                start_line: 1,
                end_line: 1,
                module_path: "Component#{j}",
                visibility: :public,
                parameters: [],
                calls: [name],
                is_a: [],
                contains: [],
                language: :typescript
              }
            end)

          noise_entity = %{
            id: "noise_#{i}",
            file_path: "/app/lib/utils.ts",
            entity_type: :function,
            name: name,
            content: "",
            start_line: i,
            end_line: i,
            module_path: name,
            visibility: :public,
            parameters: [],
            calls: [],
            is_a: [],
            contains: [],
            language: :typescript
          }

          [noise_entity | callers]
        end)
        |> List.flatten()

      ChunkCache.clear()
      GraphCache.clear()
      ChunkCache.insert_many(noise_chunks)
      GraphCache.rebuild_from_chunks(noise_chunks)

      {:ok, stats} = Queries.get_graph_stats()
      top_names = Enum.map(stats.top_connected, & &1.name)

      refute "cn" in top_names, "cn should be filtered from top_connected"
      refute "clsx" in top_names, "clsx should be filtered from top_connected"
      refute "Comp" in top_names, "Comp should be filtered from top_connected"
    end

    test "legitimate high-connectivity app nodes are NOT filtered" do
      # A real app function called by many components should still appear in top_connected
      callers =
        1..20
        |> Enum.map(fn j ->
          %{
            id: "caller_fetch_#{j}",
            file_path: "/app/components/c#{j}.tsx",
            entity_type: :function,
            name: "Component#{j}.render",
            content: "",
            start_line: 1,
            end_line: 1,
            module_path: "Component#{j}",
            visibility: :public,
            parameters: [],
            calls: ["fetchUsers"],
            is_a: [],
            contains: [],
            language: :typescript
          }
        end)

      fetch_entity = %{
        id: "fetch_users",
        file_path: "/app/lib/api.ts",
        entity_type: :function,
        name: "fetchUsers",
        content: "",
        start_line: 1,
        end_line: 1,
        module_path: "fetchUsers",
        visibility: :public,
        parameters: [],
        calls: [],
        is_a: [],
        contains: [],
        language: :typescript
      }

      ChunkCache.clear()
      GraphCache.clear()
      ChunkCache.insert_many([fetch_entity | callers])
      GraphCache.rebuild_from_chunks([fetch_entity | callers])

      {:ok, stats} = Queries.get_graph_stats()
      top_names = Enum.map(stats.top_connected, & &1.name)

      assert "fetchUsers" in top_names,
             "Legitimate high-connectivity function should appear in top_connected"
    end
  end

  describe "get_graph_stats/0 - builtins and stdlib calls don't make hubs" do
    defp gnode(attrs) do
      attrs = Map.new(attrs)

      Map.merge(
        %{
          id: "#{attrs[:file_path]}:#{attrs[:name]}",
          entity_type: :function,
          content: "",
          start_line: 1,
          end_line: 1,
          module_path: nil,
          visibility: :public,
          parameters: [],
          calls: [],
          is_a: [],
          contains: []
        },
        attrs
      )
    end

    defp stats(chunks) do
      ChunkCache.clear()
      GraphCache.clear()
      ChunkCache.insert_many(chunks)
      GraphCache.rebuild_from_chunks(chunks)
      {:ok, stats} = Queries.get_graph_stats()
      stats
    end

    test "language builtins and stdlib-qualified calls don't credit same-named project entities" do
      # gpt-alpha: `len` 178 and `sorted` 111 topped the list from Python builtin
      # calls; elixir-nexus: `get` and `info` from Map.get / Logger.info.
      callers =
        for i <- 1..12 do
          gnode(
            name: "step_#{i}",
            language: :python,
            file_path: "/w/train_#{i}.py",
            calls: ["len", "sorted", "print", "train_model"]
          )
        end

      elixir_callers =
        for i <- 1..12 do
          gnode(
            name: "Worker#{i}.run",
            language: :elixir,
            file_path: "/w/lib/worker_#{i}.ex",
            calls: ["Map.get", "Logger.info", "Enum.map"]
          )
        end

      result =
        stats(
          callers ++
            elixir_callers ++
            [
              gnode(name: "len", language: :python, file_path: "/w/utils/shape.py"),
              gnode(name: "train_model", language: :python, file_path: "/w/train.py"),
              gnode(name: "Cache.get", language: :elixir, file_path: "/w/lib/cache.ex"),
              gnode(name: "Log.info", language: :elixir, file_path: "/w/lib/log.ex")
            ]
        )

      top = Enum.map(result.top_connected, & &1.name)
      assert hd(top) == "train_model"
      refute "len" in Enum.take(top, 3)
      refute "Cache.get" in Enum.take(top, 3)
      refute "Log.info" in Enum.take(top, 3)
    end

    test "test files neither rank nor inflate production entities" do
      # control-stack: `evidence` (a const in five test files) ranked first at 309,
      # and findControl's 273 was mostly test call sites.
      test_nodes =
        for i <- 1..15 do
          gnode(
            name: "evidence",
            entity_type: :variable,
            language: :typescript,
            file_path: "/app/services/evaluator_#{i}.test.ts",
            start_line: i,
            calls: ["findControl", "evidence"]
          )
        end

      prod_callers =
        for i <- 1..3 do
          gnode(
            name: "evaluate_#{i}",
            language: :typescript,
            file_path: "/app/services/eval_#{i}.ts",
            calls: ["createEvidence"]
          )
        end

      result =
        stats(
          test_nodes ++
            prod_callers ++
            [
              gnode(name: "findControl", language: :typescript, file_path: "/app/services/find.ts"),
              gnode(name: "createEvidence", language: :typescript, file_path: "/app/services/create.ts")
            ]
        )

      top = Enum.map(result.top_connected, & &1.name)
      refute "evidence" in top
      assert hd(top) == "createEvidence"
    end

    test "critical_files leaves out test and generated files" do
      chain = fn prefix, file ->
        [
          gnode(name: "#{prefix}_a", language: :typescript, file_path: file, calls: ["#{prefix}_b"]),
          gnode(name: "#{prefix}_b", language: :typescript, file_path: file, calls: ["#{prefix}_c"]),
          gnode(name: "#{prefix}_c", language: :typescript, file_path: file, calls: ["#{prefix}_d"]),
          gnode(name: "#{prefix}_d", language: :typescript, file_path: file)
        ]
      end

      result =
        stats(
          chain.("gen", "/app/src/wire/generated.js") ++
            chain.("spec", "/app/src/wire/conformance.test.ts") ++
            chain.("real", "/app/src/lib/restore-client.ts")
        )

      files = Enum.map(result.critical_files, & &1.file_path)
      assert "/app/src/lib/restore-client.ts" in files
      refute "/app/src/wire/generated.js" in files
      refute "/app/src/wire/conformance.test.ts" in files
    end
  end
end
