defmodule ElixirNexus.PubSubPerformanceTest do
  use ExUnit.Case, async: false

  @moduletag :performance

  alias ElixirNexus.ChunkCache
  alias ElixirNexus.GraphCache
  alias ElixirNexus.Events

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp measure(fun) do
    {elapsed_us, result} = :timer.tc(fun)
    {result, elapsed_us / 1_000}
  end

  defp ensure_ets_table(name) do
    case :ets.info(name) do
      :undefined -> :ets.new(name, [:set, :public, :named_table, read_concurrency: true])
      _ -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    ensure_ets_table(:nexus_chunk_cache)
    ensure_ets_table(:nexus_graph_cache)

    on_exit(fn ->
      try do
        ChunkCache.clear()
      rescue
        _ -> :ok
      end

      try do
        GraphCache.clear()
      rescue
        _ -> :ok
      end
    end)

    temp_dir = Path.join(System.tmp_dir!(), "perf_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, temp_dir: temp_dir}
  end

  # ===========================================================================
  # 7. PubSub Delivery Latency
  # ===========================================================================

  describe "PubSub delivery latency" do
    test "subscribe + broadcast round-trip" do
      Events.subscribe_indexing()

      {_result, elapsed} =
        measure(fn ->
          Events.broadcast_indexing_progress(%{file: "test.ex", progress: 50})

          receive do
            {:indexing_progress, _data} -> :ok
          after
            1_000 -> flunk("No message received within 1s")
          end
        end)

      IO.puts("\n  pubsub round-trip: #{Float.round(elapsed, 2)}ms")
      assert elapsed < 5, "PubSub round-trip took #{Float.round(elapsed, 2)}ms (> 5ms)"
    end

    test "100 subscribers, 1 broadcast — all receive within 50ms" do
      parent = self()

      pids =
        Enum.map(1..100, fn i ->
          spawn(fn ->
            Events.subscribe_indexing()
            send(parent, {:subscribed, i})

            receive do
              {:indexing_complete, _data} ->
                send(parent, {:received, i, System.monotonic_time(:microsecond)})
            after
              5_000 -> send(parent, {:timeout, i})
            end
          end)
        end)

      # Wait for all subscribers to register
      Enum.each(1..100, fn _ ->
        receive do
          {:subscribed, _} -> :ok
        after
          5_000 -> flunk("Subscriber registration timed out")
        end
      end)

      # Small delay to ensure PubSub registrations propagate
      Process.sleep(10)

      broadcast_time = System.monotonic_time(:microsecond)
      Events.broadcast_indexing_complete(%{files: 10, chunks: 100})

      results =
        Enum.map(1..100, fn _ ->
          receive do
            {:received, i, recv_time} -> {:ok, i, (recv_time - broadcast_time) / 1_000}
            {:timeout, i} -> {:timeout, i, nil}
          after
            5_000 -> {:error, :no_reply, nil}
          end
        end)

      latencies =
        results
        |> Enum.filter(fn {status, _, _} -> status == :ok end)
        |> Enum.map(fn {_, _, latency} -> latency end)
        |> Enum.sort()

      received_count = length(latencies)
      IO.puts("\n  100 subscribers: #{received_count}/100 received")

      if received_count > 0 do
        IO.puts("  max latency: #{Float.round(Enum.max(latencies), 2)}ms")
        assert Enum.max(latencies) < 50, "Max delivery latency exceeded 50ms"
      end

      assert received_count == 100, "Only #{received_count}/100 subscribers received the message"

      # Cleanup
      Enum.each(pids, fn pid -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    end

    test "rapid-fire 100 broadcasts — no message loss" do
      Events.subscribe_indexing()

      Enum.each(1..100, fn i ->
        Events.broadcast_indexing_progress(%{file: "test_#{i}.ex", progress: i})
      end)

      received =
        Enum.reduce_while(1..100, 0, fn _, acc ->
          receive do
            {:indexing_progress, _data} -> {:cont, acc + 1}
          after
            2_000 -> {:halt, acc}
          end
        end)

      IO.puts("\n  rapid-fire: #{received}/100 messages received")
      assert received == 100, "Lost #{100 - received} messages out of 100"
    end
  end
end
