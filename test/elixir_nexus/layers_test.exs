defmodule ElixirNexus.LayersTest do
  use ExUnit.Case, async: true

  alias ElixirNexus.Layers

  describe "classify/1" do
    test "ports win over domain when both segments present" do
      assert Layers.classify("core/ports/repositories/repository-host.ts") == "ports"
    end

    test "domain entities" do
      assert Layers.classify("core/entities/evidence.ts") == "domain"
    end

    test "adapters / infrastructure" do
      assert Layers.classify("infrastructure/providers/aws-connector.ts") == "adapters"
    end

    test "application services" do
      assert Layers.classify("services/sync/execute-sync.ts") == "application"
    end

    test "repositories" do
      assert Layers.classify("repositories/compliance/breach-repository.ts") == "repositories"
    end

    test "api routes win over presentation app/" do
      assert Layers.classify("app/api/integrations/route.ts") == "api"
    end

    test "presentation" do
      assert Layers.classify("components/app-shell.tsx") == "presentation"
      assert Layers.classify("hooks/use-mobile.ts") == "presentation"
    end

    test "works on absolute paths" do
      assert Layers.classify("/Users/x/proj/core/ports/p.ts") == "ports"
    end

    test "unknown layout is other" do
      assert Layers.classify("random/path/thing.ts") == "other"
    end
  end
end
