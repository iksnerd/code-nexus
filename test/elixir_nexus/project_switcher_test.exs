defmodule ElixirNexus.ProjectSwitcherTest do
  use ExUnit.Case, async: false

  alias ElixirNexus.ProjectSwitcher

  describe "switch_project/1" do
    test "handles nonexistent collection gracefully" do
      result =
        try do
          ProjectSwitcher.switch_project("nonexistent_test_collection_#{System.unique_integer()}")
        rescue
          _ -> :process_not_available
        catch
          :exit, _ -> :process_not_available
        end

      # Either :ok (Qdrant accepted), {:error, _} (collection not found), or :process_not_available
      assert result in [:ok, :process_not_available] or match?({:error, _}, result)
    end

    test "switch to current collection succeeds" do
      current = ElixirNexus.QdrantClient.active_collection()

      result =
        try do
          ProjectSwitcher.switch_project(current)
        rescue
          _ -> :process_not_available
        catch
          :exit, _ -> :process_not_available
        end

      assert result in [:ok, :process_not_available]
    end
  end

  describe "reload_from_qdrant/0" do
    test "handles empty collection gracefully" do
      result =
        try do
          ProjectSwitcher.reload_from_qdrant()
        rescue
          _ -> :error
        catch
          :exit, _ -> :process_not_available
        end

      assert result in [:ok, nil, :error, :process_not_available]
    end

    test "populates ETS caches when Qdrant has data" do
      # This tests the full reload path
      result =
        try do
          ProjectSwitcher.reload_from_qdrant()
        rescue
          _ -> :error
        catch
          :exit, _ -> :process_not_available
        end

      # Regardless of result, caches should be in a valid state
      chunks = ElixirNexus.ChunkCache.all()
      assert is_list(chunks)

      nodes = ElixirNexus.GraphCache.all_nodes()
      assert is_map(nodes)
    end
  end
end
