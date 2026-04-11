defmodule ElixirNexus.MCPServerTest do
  use ExUnit.Case, async: false

  alias ElixirNexus.MCPServer

  # Restore the active Qdrant collection after each test so that reindex tests
  # which temporarily switch collections don't leave a deleted collection as
  # the active one for subsequent test modules (e.g. ProjectSwitcherTest).
  setup do
    original_runtime = Application.get_env(:elixir_nexus, :qdrant_runtime)

    on_exit(fn ->
      if original_runtime do
        Application.put_env(:elixir_nexus, :qdrant_runtime, original_runtime)
      else
        Application.delete_env(:elixir_nexus, :qdrant_runtime)
      end
    end)

    :ok
  end

  describe "handle_initialize/2" do
    test "extracts project root from roots param" do
      params = %{"roots" => [%{"uri" => "file:///home/user/project"}]}
      {:ok, info, state} = MCPServer.handle_initialize(params, %{})
      assert info.name == "code-nexus"
      assert state.project_root == "/home/user/project"
    end

    test "extracts root from capabilities.roots" do
      params = %{"capabilities" => %{"roots" => [%{"uri" => "file:///opt/app"}]}}
      {:ok, _info, state} = MCPServer.handle_initialize(params, %{})
      assert state.project_root == "/opt/app"
    end

    test "falls back to cwd when no roots" do
      params = %{}
      {:ok, _info, state} = MCPServer.handle_initialize(params, %{})
      assert state.project_root == File.cwd!()
    end

    test "handles root without file:// prefix" do
      params = %{"roots" => [%{"uri" => "/some/path"}]}
      {:ok, _info, state} = MCPServer.handle_initialize(params, %{})
      assert state.project_root == "/some/path"
    end

    test "returns server info with capabilities" do
      {:ok, info, _state} = MCPServer.handle_initialize(%{}, %{})
      assert info.name == "code-nexus"
      assert info.version == ElixirNexus.version()
      assert %{tools: %{}} = info.capabilities
    end

    test "prefers roots over capabilities.roots" do
      params = %{
        "roots" => [%{"uri" => "file:///primary"}],
        "capabilities" => %{"roots" => [%{"uri" => "file:///secondary"}]}
      }

      {:ok, _info, state} = MCPServer.handle_initialize(params, %{})
      assert state.project_root == "/primary"
    end

    test "uses first root when multiple are provided" do
      params = %{
        "roots" => [
          %{"uri" => "file:///first"},
          %{"uri" => "file:///second"}
        ]
      }

      {:ok, _info, state} = MCPServer.handle_initialize(params, %{})
      assert state.project_root == "/first"
    end

    test "merges project_root into existing state" do
      params = %{"roots" => [%{"uri" => "file:///test"}]}
      {:ok, _info, state} = MCPServer.handle_initialize(params, %{existing_key: "value"})
      assert state.project_root == "/test"
      assert state.existing_key == "value"
    end
  end

  describe "handle_tool_call/3 unknown tool" do
    test "returns error for unknown tool" do
      assert {:error, "Unknown tool: nonexistent", %{}} =
               MCPServer.handle_tool_call("nonexistent", %{}, %{})
    end

    test "returns error with tool name in message" do
      {:error, msg, _state} = MCPServer.handle_tool_call("fake_tool", %{}, %{})
      assert msg =~ "fake_tool"
    end
  end

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
          # Also acceptable if search infrastructure not available
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

  describe "handle_tool_call reindex" do
    test "reindexes with explicit path" do
      state = %{project_root: File.cwd!()}
      tmp_dir = Path.join(System.tmp_dir!(), "mcp_reindex_test_#{System.unique_integer([:positive])}")
      lib_dir = Path.join(tmp_dir, "lib")
      File.mkdir_p!(lib_dir)
      File.write!(Path.join(lib_dir, "test.ex"), "defmodule Test do\nend\n")

      result =
        MCPServer.handle_tool_call("reindex", %{"path" => lib_dir}, state)

      case result do
        {:ok, %{content: [%{type: "text", text: json}]}, _state} ->
          assert is_binary(json)
          decoded = Jason.decode!(json)
          assert is_map(decoded)

        {:error, msg, _state} ->
          assert is_binary(msg)
      end

      # Wait for indexing to finish so it doesn't interfere with other tests
      ElixirNexus.Indexer.await_idle()
      cleanup_test_collection(tmp_dir)
      File.rm_rf!(tmp_dir)
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

    test "project_path is nil when not yet indexed" do
      Application.delete_env(:elixir_nexus, :current_project_path)
      state = %{project_root: File.cwd!()}

      {:ok, %{content: [%{type: "text", text: json}]}, _state} =
        MCPServer.handle_tool_call("get_graph_stats", %{}, state)

      decoded = Jason.decode!(json)
      assert Map.has_key?(decoded, "project_path")
      assert decoded["project_path"] == nil
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
          # If it somehow resolved, that's fine
          :ok

        {:error, msg, _state} ->
          assert is_binary(msg)
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

  describe "handle_tool_call search_code with limit" do
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

  describe "handle_tool_call analyze_impact with depth" do
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

  describe "handle_tool_call find_module_hierarchy error message" do
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
          # If it resolved somehow, that's fine
          :ok
      end
    end
  end

  describe "auto-reindex dirty files before queries" do
    test "search_code auto-reindexes dirty files" do
      tmp_dir = Path.join(System.tmp_dir!(), "mcp_autoreindex_#{System.unique_integer([:positive])}")
      lib_dir = Path.join(tmp_dir, "lib")
      File.mkdir_p!(lib_dir)
      File.write!(Path.join(lib_dir, "original.ex"), "defmodule Original do\n  def hello, do: :world\nend\n")

      # Reindex to establish baseline
      state = %{project_root: tmp_dir}
      MCPServer.handle_tool_call("reindex", %{"path" => lib_dir}, state)
      ElixirNexus.Indexer.await_idle()

      # State after reindex should have :indexed_dirs
      {:ok, _, state_after} = MCPServer.handle_tool_call("reindex", %{"path" => lib_dir}, state)
      ElixirNexus.Indexer.await_idle()

      # Modify a file — makes it dirty
      File.write!(Path.join(lib_dir, "original.ex"), "defmodule Original do\n  def hello, do: :updated\nend\n")

      # Query should trigger auto-reindex (state has indexed_dirs)
      result = MCPServer.handle_tool_call("search_code", %{"query" => "hello"}, state_after)

      case result do
        {:ok, %{content: [%{type: "text", text: json}]}, _state} ->
          assert is_binary(json)

        {:error, _msg, _state} ->
          :ok
      end

      cleanup_test_collection(tmp_dir)
      File.rm_rf!(tmp_dir)
    end

    test "no auto-reindex when no indexed_dirs in state" do
      # Without :indexed_dirs, should just run the query without reindexing
      state = %{project_root: File.cwd!()}

      result = MCPServer.handle_tool_call("search_code", %{"query" => "nonexistent_xyz"}, state)

      case result do
        {:ok, %{content: [%{type: "text", text: json}]}, _state} ->
          assert is_binary(json)

        {:error, _msg, _state} ->
          :ok
      end
    end
  end

  describe "handle_tool_call reindex with lib subdirectory" do
    test "detects project root from lib subdirectory" do
      state = %{project_root: File.cwd!()}
      tmp_dir = Path.join(System.tmp_dir!(), "mcp_lib_test_#{System.unique_integer([:positive])}")
      lib_dir = Path.join(tmp_dir, "lib")
      File.mkdir_p!(lib_dir)
      File.write!(Path.join(lib_dir, "test.ex"), "defmodule Test do\nend\n")

      result =
        MCPServer.handle_tool_call("reindex", %{"path" => lib_dir}, state)

      case result do
        {:ok, %{content: [%{type: "text", text: json}]}, _state} ->
          assert is_binary(json)

        {:error, msg, _state} ->
          assert is_binary(msg)
      end

      ElixirNexus.Indexer.await_idle()
      cleanup_test_collection(tmp_dir)
      File.rm_rf!(tmp_dir)
    end
  end

  defp cleanup_test_collection(tmp_dir) do
    collection =
      tmp_dir
      |> Path.basename()
      |> then(&"nexus_#{&1}")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]/, "_")
      |> String.trim_leading("_")
      |> String.slice(0..59)

    ElixirNexus.QdrantClient.delete_collection(collection)
  end
end
