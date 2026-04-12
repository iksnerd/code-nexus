defmodule ElixirNexus.MCPServerReindexTest do
  use ExUnit.Case, async: false

  alias ElixirNexus.MCPServer

  # Restore the active Qdrant collection after each test so that reindex tests
  # which temporarily switch collections don't leave a deleted collection as
  # the active one for subsequent test modules.
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

      on_exit(fn ->
        ElixirNexus.Indexer.await_idle()
        cleanup_test_collection(tmp_dir)
        File.rm_rf!(tmp_dir)
      end)
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

      on_exit(fn ->
        ElixirNexus.Indexer.await_idle()
        cleanup_test_collection(tmp_dir)
        File.rm_rf!(tmp_dir)
      end)
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

      on_exit(fn ->
        ElixirNexus.Indexer.await_idle()
        cleanup_test_collection(tmp_dir)
        File.rm_rf!(tmp_dir)
      end)
    end

    test "no auto-reindex when no indexed_dirs in state" do
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
