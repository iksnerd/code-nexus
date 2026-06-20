defmodule ElixirNexus.ProjectConfigTest do
  use ExUnit.Case, async: true

  alias ElixirNexus.ProjectConfig

  describe "parse/1" do
    test "parses entry_points.include" do
      toml = """
      [entry_points]
      include = ["app/**/route.ts", "app/sitemap.ts"]
      """

      cfg = ProjectConfig.parse(toml)
      assert cfg.entry_points == ["app/**/route.ts", "app/sitemap.ts"]
    end

    test "parses layers" do
      toml = """
      [layers]
      ports = "core/ports/**"
      adapters = "infrastructure/**"
      """

      cfg = ProjectConfig.parse(toml)
      assert cfg.layers == %{"ports" => "core/ports/**", "adapters" => "infrastructure/**"}
    end

    test "empty for missing sections" do
      cfg = ProjectConfig.parse("")
      assert cfg.entry_points == []
      assert cfg.layers == %{}
    end

    test "never raises on invalid toml" do
      cfg = ProjectConfig.parse("this is = = not valid toml [[[")
      assert cfg.entry_points == []
    end
  end

  describe "glob_match?/2" do
    test "** spans path segments" do
      assert ProjectConfig.glob_match?("app/**/route.ts", "app/api/users/route.ts")
      assert ProjectConfig.glob_match?("app/**/route.ts", "app/route.ts")
      refute ProjectConfig.glob_match?("app/**/route.ts", "app/api/users/page.ts")
    end

    test "* stays within a segment" do
      assert ProjectConfig.glob_match?("app/*.ts", "app/sitemap.ts")
      refute ProjectConfig.glob_match?("app/*.ts", "app/api/sitemap.ts")
    end

    test "exact path matches" do
      assert ProjectConfig.glob_match?("app/sitemap.ts", "app/sitemap.ts")
      refute ProjectConfig.glob_match?("app/sitemap.ts", "app/sitemap.tsx")
    end

    test "leading **/ matches any depth" do
      assert ProjectConfig.glob_match?("**/route.ts", "app/api/route.ts")
      assert ProjectConfig.glob_match?("**/route.ts", "route.ts")
    end
  end

  describe "entry_point?/2" do
    test "true when a glob matches" do
      cfg = %ProjectConfig{entry_points: ["app/**/route.ts", "app/sitemap.ts"]}
      assert ProjectConfig.entry_point?(cfg, "app/api/users/route.ts")
      assert ProjectConfig.entry_point?(cfg, "app/sitemap.ts")
    end

    test "false when no glob matches" do
      cfg = %ProjectConfig{entry_points: ["app/**/route.ts"]}
      refute ProjectConfig.entry_point?(cfg, "lib/utils.ts")
    end

    test "false with no entry points" do
      refute ProjectConfig.entry_point?(%ProjectConfig{}, "anything.ts")
    end
  end

  describe "layer_for/2" do
    test "config [layers] glob overrides derivation" do
      cfg = %ProjectConfig{layers: %{"gateway" => "edge/**"}}
      assert ProjectConfig.layer_for(cfg, "edge/handler.ts") == "gateway"
    end

    test "falls back to convention derivation when no config glob matches" do
      cfg = %ProjectConfig{layers: %{"gateway" => "edge/**"}}
      assert ProjectConfig.layer_for(cfg, "core/ports/repo.ts") == "ports"
    end

    test "empty config derives by convention" do
      assert ProjectConfig.layer_for(%ProjectConfig{}, "infrastructure/x.ts") == "adapters"
    end
  end

  describe "load/1 and load_and_store/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "nexus_cfg_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "empty struct when file is absent", %{dir: dir} do
      cfg = ProjectConfig.load(dir)
      assert cfg.entry_points == []
    end

    test "reads .nexus.toml from the directory", %{dir: dir} do
      File.write!(Path.join(dir, ".nexus.toml"), """
      [entry_points]
      include = ["app/sitemap.ts"]
      """)

      cfg = ProjectConfig.load(dir)
      assert cfg.entry_points == ["app/sitemap.ts"]
    end

    test "load_and_store caches {root, config} in current/0", %{dir: dir} do
      File.write!(Path.join(dir, ".nexus.toml"), """
      [entry_points]
      include = ["app/manifest.ts"]
      """)

      ProjectConfig.load_and_store(dir)
      assert {^dir, %ProjectConfig{entry_points: ["app/manifest.ts"]}} = ProjectConfig.current()
    end
  end
end
