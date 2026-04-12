defmodule ElixirNexus.MCPServerInitTest do
  use ExUnit.Case, async: false

  alias ElixirNexus.MCPServer

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
end
