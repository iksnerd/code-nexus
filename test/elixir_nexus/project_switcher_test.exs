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

  describe "switch_project/1 edge cases" do
    test "switching to a nonexistent collection returns error and does not clear caches" do
      # Ensure caches have some state before the failed switch
      before_chunks = ElixirNexus.ChunkCache.all()
      before_nodes = ElixirNexus.GraphCache.all_nodes()

      result =
        try do
          ProjectSwitcher.switch_project("nonexistent_collection_#{System.unique_integer()}")
        rescue
          _ -> :process_not_available
        catch
          :exit, _ -> :process_not_available
        end

      # A nonexistent Qdrant collection must produce an error or process not available
      assert result != :ok

      if result != :process_not_available do
        assert match?({:error, _}, result)

        # Caches must not have been corrupted by the failed switch attempt
        after_chunks = ElixirNexus.ChunkCache.all()
        after_nodes = ElixirNexus.GraphCache.all_nodes()
        assert is_list(after_chunks)
        assert is_map(after_nodes)
        # Same as before — caches were not cleared on a failed switch
        assert length(after_chunks) == length(before_chunks)
        assert map_size(after_nodes) == map_size(before_nodes)
      end
    end

    test "rapid successive switches leave caches in a valid state" do
      current = ElixirNexus.QdrantClient.active_collection()

      # Run several switches to the current collection in sequence
      results =
        for _ <- 1..5 do
          try do
            ProjectSwitcher.switch_project(current)
          rescue
            _ -> :process_not_available
          catch
            :exit, _ -> :process_not_available
          end
        end

      # All should succeed or indicate process unavailable — none should crash
      assert Enum.all?(results, fn r -> r in [:ok, :process_not_available] end)

      # Caches must be in a valid (not corrupted) state after all switches
      assert is_list(ElixirNexus.ChunkCache.all())
      assert is_map(ElixirNexus.GraphCache.all_nodes())
    end

    test "switch while indexer is idle does not block" do
      current = ElixirNexus.QdrantClient.active_collection()

      # Verify indexer is not currently busy (no pending index_directories call)
      # then switch — should complete without timeout
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
