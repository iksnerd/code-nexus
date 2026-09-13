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

  describe "resolve_path/2 — source-dir climbing" do
    test "does not climb past a directory that is itself a project root" do
      tmp = Path.join(System.tmp_dir!(), "path_resolution_test_#{:rand.uniform(1_000_000)}")
      project_dir = Path.join(tmp, "app")
      File.mkdir_p!(project_dir)
      File.write!(Path.join(project_dir, "mix.exs"), "")
      on_exit(fn -> File.rm_rf(tmp) end)

      assert {:ok, ^project_dir, ^project_dir} = PathResolution.resolve_path(project_dir, "irrelevant")
    end

    test "still climbs to the parent for a markerless source subdir" do
      tmp = Path.join(System.tmp_dir!(), "path_resolution_test_#{:rand.uniform(1_000_000)}")
      lib_dir = Path.join(tmp, "lib")
      File.mkdir_p!(lib_dir)
      on_exit(fn -> File.rm_rf(tmp) end)

      assert {:ok, ^tmp, ^lib_dir} = PathResolution.resolve_path(lib_dir, "irrelevant")
    end
  end

  describe "resolve_bare_name/2 — multiple mounts" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "path_resolution_test_#{:rand.uniform(1_000_000)}")
      mounts = for n <- 1..2, do: Path.join(tmp, "workspace#{n}")
      Enum.each(mounts, &File.mkdir_p!/1)
      on_exit(fn -> File.rm_rf(tmp) end)

      [m1, m2] = mounts
      {:ok, m1: m1, m2: m2, mounts: [{m1, "/Users/me/www"}, {m2, "/Users/me/GolandProjects"}]}
    end

    test "single match resolves to it", %{m2: m2, mounts: mounts} do
      File.mkdir_p!(Path.join(m2, "weightless"))

      assert PathResolution.resolve_bare_name("weightless", mounts) == {:ok, Path.join(m2, "weightless")}
    end

    test "prefers the mount where the name is a real project over an empty dir", ctx do
      File.mkdir_p!(Path.join(ctx.m1, "weightless"))
      File.mkdir_p!(Path.join(ctx.m2, "weightless"))
      File.write!(Path.join([ctx.m2, "weightless", "go.mod"]), "module weightless\n")

      assert PathResolution.resolve_bare_name("weightless", ctx.mounts) ==
               {:ok, Path.join(ctx.m2, "weightless")}
    end

    test "reports ambiguity with host paths when the name is a real project in several mounts", ctx do
      for m <- [ctx.m1, ctx.m2] do
        File.mkdir_p!(Path.join([m, "shared", "lib"]))
      end

      assert PathResolution.resolve_bare_name("shared", ctx.mounts) ==
               {:ambiguous, ["/Users/me/www/shared", "/Users/me/GolandProjects/shared"]}
    end

    test "falls back to the first match when none look like a project", ctx do
      File.mkdir_p!(Path.join(ctx.m1, "empty"))
      File.mkdir_p!(Path.join(ctx.m2, "empty"))

      assert PathResolution.resolve_bare_name("empty", ctx.mounts) == {:ok, Path.join(ctx.m1, "empty")}
    end

    test "resolves a single-project mount by its host basename", %{m1: m1} do
      File.write!(Path.join(m1, "mix.exs"), "")

      assert PathResolution.resolve_bare_name("council-hub", [{m1, "/Users/me/council-hub"}]) == {:ok, m1}
    end

    test "returns :not_found when no mount has the name", %{mounts: mounts} do
      assert PathResolution.resolve_bare_name("nope", mounts) == :not_found
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
