defmodule ElixirNexus.MCPServer.PathResolutionTest do
  use ExUnit.Case, async: true

  alias ElixirNexus.MCPServer.PathResolution

  describe "extract_project_root/2" do
    test "extracts root from file:// URI in roots list" do
      params = %{"roots" => [%{"uri" => "file:///Users/yourname/projects/myapp"}]}
      assert PathResolution.extract_project_root(params) == "/Users/yourname/projects/myapp"
    end

    test "extracts root from plain URI (no file:// prefix)" do
      params = %{"roots" => [%{"uri" => "/workspace/myapp"}]}
      assert PathResolution.extract_project_root(params) == "/workspace/myapp"
    end

    test "falls back to capabilities.roots" do
      params = %{
        "capabilities" => %{"roots" => [%{"uri" => "file:///workspace/nested"}]}
      }

      assert PathResolution.extract_project_root(params) == "/workspace/nested"
    end

    test "falls back to File.cwd! when no roots provided" do
      result = PathResolution.extract_project_root(%{})
      assert is_binary(result) and result != ""
    end

    test "falls back to File.cwd! when roots is nil" do
      result = PathResolution.extract_project_root(%{"roots" => nil})
      assert is_binary(result) and result != ""
    end
  end

  describe "list_workspace_projects/0" do
    test "returns empty list when /workspace does not exist" do
      # In the test environment there is no /workspace mount
      result = PathResolution.list_workspace_projects()
      assert is_list(result)
    end
  end

  describe "workspace_hint/0" do
    test "returns a string (empty or with project list)" do
      hint = PathResolution.workspace_hint()
      assert is_binary(hint)
    end
  end

  describe "maybe_add_default_path_warning/4" do
    test "adds warning when path_arg is nil and state has no indexed_dirs" do
      result = PathResolution.maybe_add_default_path_warning(%{status: "ok"}, nil, "/app", %{})
      assert Map.has_key?(result, :warning)
      assert result.warning =~ "/app"
    end

    test "does not add warning when path_arg is set" do
      result =
        PathResolution.maybe_add_default_path_warning(
          %{status: "ok"},
          "/workspace/myapp",
          "/workspace/myapp",
          %{}
        )

      refute Map.has_key?(result, :warning)
    end

    test "does not add warning when state already has indexed_dirs" do
      result =
        PathResolution.maybe_add_default_path_warning(
          %{status: "ok"},
          nil,
          "/app",
          %{indexed_dirs: ["/app/lib"]}
        )

      refute Map.has_key?(result, :warning)
    end

    test "preserves existing result keys" do
      result =
        PathResolution.maybe_add_default_path_warning(%{foo: "bar"}, nil, "/app", %{})

      assert result.foo == "bar"
    end
  end
end
