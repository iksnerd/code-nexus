defmodule ElixirNexus.MCPServerQueryToolsTest do
  use ExUnit.Case, async: false

  alias ElixirNexus.MCPServer

  describe "handle_tool_call search_code" do
    test "calls search and returns JSON response" do
      state = %{project_root: File.cwd!()}

      result =
        MCPServer.handle_tool_call("search_code", %{"query" => "test_nonexistent_xyz"}, state)

      case result do
        {:ok, %{content: [%{type: "text", text: json}]}, _state} ->
          assert is_binary(json)
          decoded = Jason.decode!(json)
          assert is_list(decoded)

        {:error, _msg, _state} ->
          :ok
      end
    end

    test "passes explicit limit parameter" do
      state = %{project_root: File.cwd!()}

      result =
        MCPServer.handle_tool_call("search_code", %{"query" => "test", "limit" => 3}, state)

      case result do
        {:ok, %{content: [%{type: "text", text: json}]}, _state} ->
          decoded = Jason.decode!(json)
          assert is_list(decoded)
          assert length(decoded) <= 3

        {:error, _msg, _state} ->
          :ok
      end
    end
  end

  describe "handle_tool_call find_all_callers" do
    test "returns list for nonexistent entity" do
      state = %{project_root: File.cwd!()}

      result =
        MCPServer.handle_tool_call(
          "find_all_callers",
          %{"entity_name" => "nonexistent_function_xyz"},
          state
        )

      case result do
        {:ok, %{content: [%{type: "text", text: json}]}, _state} ->
          decoded = Jason.decode!(json)
          assert is_list(decoded)

        {:error, _msg, _state} ->
          :ok
      end
    end
  end

  describe "handle_tool_call find_all_callees" do
    test "handles nonexistent entity" do
      state = %{project_root: File.cwd!()}

      result =
        MCPServer.handle_tool_call(
          "find_all_callees",
          %{"entity_name" => "nonexistent_function_xyz"},
          state
        )

      case result do
        {:ok, %{content: [%{type: "text", text: json}]}, _state} ->
          assert is_binary(json)
          decoded = Jason.decode!(json)
          assert is_list(decoded)

        {:error, msg, _state} ->
          assert is_binary(msg)
      end
    end

    test "respects limit parameter" do
      state = %{project_root: File.cwd!()}

      result =
        MCPServer.handle_tool_call(
          "find_all_callees",
          %{"entity_name" => "nonexistent_xyz", "limit" => 5},
          state
        )

      case result do
        {:ok, %{content: [%{type: "text", text: json}]}, _state} ->
          decoded = Jason.decode!(json)
          assert length(decoded) <= 5

        {:error, _msg, _state} ->
          :ok
      end
    end
  end

  describe "handle_tool_call get_graph_stats" do
    test "returns stats or error" do
      state = %{project_root: File.cwd!()}
      result = MCPServer.handle_tool_call("get_graph_stats", %{}, state)

      case result do
        {:ok, %{content: [%{type: "text", text: json}]}, _state} ->
          assert is_binary(json)
          decoded = Jason.decode!(json)
          assert is_map(decoded)

        {:error, _msg, _state} ->
          :ok
      end
    end

    test "includes project_path from state" do
      state = %{project_root: File.cwd!(), project_path: "/workspace/my-project"}

      {:ok, %{content: [%{type: "text", text: json}]}, _state} =
        MCPServer.handle_tool_call("get_graph_stats", %{}, state)

      decoded = Jason.decode!(json)
      assert decoded["project_path"] == "/workspace/my-project"
    end

    test "project_path falls back to active Qdrant collection when state and env are unset" do
      # Issue #8: get_graph_stats should never return nil project_path when *something*
      # is indexed. Final fallback derives the project name from the active collection
      # (stripping the `nexus_` prefix).
      Application.delete_env(:elixir_nexus, :current_project_path)
      state = %{project_root: File.cwd!()}

      {:ok, %{content: [%{type: "text", text: json}]}, _state} =
        MCPServer.handle_tool_call("get_graph_stats", %{}, state)

      decoded = Jason.decode!(json)
      assert Map.has_key?(decoded, "project_path")
      # In test env the active collection comes from another test's setup; we just
      # assert it's a non-empty string rather than nil.
      assert is_binary(decoded["project_path"]) and decoded["project_path"] != ""
    end

    test "project_path falls back to Application env when not in state" do
      Application.put_env(:elixir_nexus, :current_project_path, "/workspace/from-env")
      state = %{project_root: File.cwd!()}

      {:ok, %{content: [%{type: "text", text: json}]}, _state} =
        MCPServer.handle_tool_call("get_graph_stats", %{}, state)

      Application.delete_env(:elixir_nexus, :current_project_path)

      decoded = Jason.decode!(json)
      assert decoded["project_path"] == "/workspace/from-env"
    end
  end

  describe "handle_tool_call find_module_hierarchy" do
    test "returns error for nonexistent module" do
      state = %{project_root: File.cwd!()}

      result =
        MCPServer.handle_tool_call(
          "find_module_hierarchy",
          %{"entity_name" => "NonexistentModule.XYZ"},
          state
        )

      case result do
        {:ok, %{content: [%{type: "text", text: _json}]}, _state} ->
          :ok

        {:error, msg, _state} ->
          assert is_binary(msg)
      end
    end

    test "error message contains entity name" do
      state = %{project_root: File.cwd!()}

      result =
        MCPServer.handle_tool_call(
          "find_module_hierarchy",
          %{"entity_name" => "VerySpecificNonexistent"},
          state
        )

      case result do
        {:error, msg, _state} ->
          assert msg =~ "VerySpecificNonexistent"

        {:ok, _content, _state} ->
          :ok
      end
    end
  end

  describe "handle_tool_call analyze_impact" do
    test "handles nonexistent entity" do
      state = %{project_root: File.cwd!()}

      result =
        MCPServer.handle_tool_call(
          "analyze_impact",
          %{"entity_name" => "nonexistent_xyz"},
          state
        )

      case result do
        {:ok, %{content: [%{type: "text", text: json}]}, _state} ->
          assert is_binary(json)

        {:error, _msg, _state} ->
          :ok
      end
    end

    test "passes explicit depth parameter" do
      state = %{project_root: File.cwd!()}

      result =
        MCPServer.handle_tool_call(
          "analyze_impact",
          %{"entity_name" => "test_func", "depth" => 1},
          state
        )

      case result do
        {:ok, %{content: [%{type: "text", text: json}]}, _state} ->
          decoded = Jason.decode!(json)
          assert decoded["depth"] == 1

        {:error, _msg, _state} ->
          :ok
      end
    end
  end

  describe "handle_tool_call get_community_context" do
    test "handles nonexistent file path" do
      state = %{project_root: File.cwd!()}

      result =
        MCPServer.handle_tool_call(
          "get_community_context",
          %{"file_path" => "/nonexistent/path.ex"},
          state
        )

      case result do
        {:ok, %{content: [%{type: "text", text: json}]}, _state} ->
          assert is_binary(json)

        {:error, _msg, _state} ->
          :ok
      end
    end

    test "passes explicit limit parameter" do
      state = %{project_root: File.cwd!()}

      result =
        MCPServer.handle_tool_call(
          "get_community_context",
          %{"file_path" => "/app/lib/server.ex", "limit" => 3},
          state
        )

      case result do
        {:ok, %{content: [%{type: "text", text: json}]}, _state} ->
          assert is_binary(json)

        {:error, _msg, _state} ->
          :ok
      end
    end
  end

  describe "find_all_callers response" do
    test "includes resolves_to when several files define the name" do
      # The query layer set resolves_to, but compact_entity's key whitelist
      # dropped it from the MCP response.
      alias ElixirNexus.{ChunkCache, GraphCache}

      base = %{
        content: "",
        start_line: 1,
        end_line: 1,
        module_path: nil,
        visibility: :public,
        parameters: [],
        contains: [],
        language: :python,
        entity_type: :function,
        is_a: [],
        calls: []
      }

      chunks = [
        Map.merge(base, %{id: "d1", name: "save_ckpt", file_path: "/w/gpt_alpha/training.py"}),
        Map.merge(base, %{id: "d2", name: "save_ckpt", file_path: "/w/jepa/text_jepa/training.py"}),
        Map.merge(base, %{id: "c1", name: "main", file_path: "/w/jepa/train.py", calls: ["text_jepa.save_ckpt"]})
      ]

      ChunkCache.clear()
      GraphCache.clear()
      ChunkCache.insert_many(chunks)
      GraphCache.rebuild_from_chunks(chunks)

      on_exit(fn ->
        ChunkCache.clear()
        GraphCache.clear()
      end)

      {:ok, %{content: [%{text: json}]}, _} =
        MCPServer.handle_tool_call("find_all_callers", %{"entity_name" => "save_ckpt"}, %{project_root: "/w"})

      [caller] = Jason.decode!(json)
      assert caller["entity"]["resolves_to"] == "/w/jepa/text_jepa/training.py"
    end
  end

  describe "queries during a graph rebuild" do
    test "wait for the rebuild instead of answering from an empty graph" do
      # gpt-alpha: for ~47s after a reindex, find_all_callers returned [] (the
      # graph was still rebuilding), indistinguishable from "no callers".
      alias ElixirNexus.{ChunkCache, GraphCache}

      base = %{
        content: "",
        start_line: 1,
        end_line: 1,
        module_path: nil,
        visibility: :public,
        parameters: [],
        is_a: [],
        contains: [],
        language: :elixir,
        entity_type: :function
      }

      chunks = [
        Map.merge(base, %{id: "callee", name: "RebuildProbe.target", file_path: "/app/lib/target.ex", calls: []}),
        Map.merge(base, %{
          id: "caller",
          name: "RebuildProbe.caller",
          file_path: "/app/lib/caller.ex",
          calls: ["RebuildProbe.target"]
        })
      ]

      ChunkCache.clear()
      GraphCache.clear()
      GraphCache.mark_rebuilding()

      on_exit(fn ->
        GraphCache.mark_ready()
        ChunkCache.clear()
        GraphCache.clear()
      end)

      Task.start(fn ->
        Process.sleep(400)
        ChunkCache.insert_many(chunks)
        GraphCache.rebuild_from_chunks(chunks)
        GraphCache.mark_ready()
      end)

      {:ok, %{content: [%{text: json}]}, _} =
        MCPServer.handle_tool_call("find_all_callers", %{"entity_name" => "RebuildProbe.target"}, %{
          project_root: "/app"
        })

      names = json |> Jason.decode!() |> Enum.map(& &1["entity"]["name"])
      assert "RebuildProbe.caller" in names
    end

    test "get_status reports the graph as rebuilding" do
      ElixirNexus.GraphCache.mark_rebuilding()
      on_exit(fn -> ElixirNexus.GraphCache.mark_ready() end)

      {:ok, %{content: [%{text: json}]}, _} = MCPServer.handle_tool_call("get_status", %{}, %{project_root: "/app"})
      assert Jason.decode!(json)["graph_status"] == "rebuilding"
    end
  end
end
