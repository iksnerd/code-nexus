defmodule ElixirNexus.Search.ElixirDeadChainTest do
  @moduledoc """
  Dead code by chains: a function whose callers are all dead is dead too, listed
  under `dead_via_dead_callers`, never mixed with the directly dead ones.
  """
  use ExUnit.Case, async: false

  alias ElixirNexus.{Chunker, ChunkCache, GraphCache, Parser}
  alias ElixirNexus.Search.Queries

  @sources %{
    "/chain/lib/chain/top.ex" => """
    defmodule Chain.Top do
      def top(x), do: Chain.Mid.mid(x)
    end
    """,
    "/chain/lib/chain/mid.ex" => """
    defmodule Chain.Mid do
      def mid(x), do: Chain.Leaf.leaf(x)
    end
    """,
    "/chain/lib/chain/leaf.ex" => """
    defmodule Chain.Leaf do
      def leaf(x), do: x
    end
    """,
    "/chain/lib/chain/cycle.ex" => """
    defmodule Chain.Cycle do
      def ping(0), do: :done
      def ping(n), do: pong(n - 1)
      def pong(n), do: ping(n)
    end
    """,
    "/chain/lib/chain/private_link.ex" => """
    defmodule Chain.PrivateLink do
      def entry_dead(x), do: step(x)
      defp step(x), do: Chain.Target.through_private(x)
    end
    """,
    "/chain/lib/chain/target.ex" => """
    defmodule Chain.Target do
      def through_private(x), do: x
      def kept(x), do: x
    end
    """,
    "/chain/lib/chain/server.ex" => """
    defmodule Chain.Server do
      use GenServer
      @impl true
      def init(x), do: {:ok, Chain.Live.used(x)}
    end
    """,
    "/chain/lib/chain/live.ex" => """
    defmodule Chain.Live do
      def used(x), do: Chain.Target.kept(x)
    end
    """,
    "/chain/lib/chain/defaults.ex" => """
    defmodule Chain.Defaults do
      def walk(list, acc \\\\ [])
      def walk([], acc), do: acc
      def walk([h | t], acc), do: walk(t) ++ [h | acc]
    end
    """,
    "/chain/lib/chain/dyn.ex" => """
    defmodule Chain.Dyn do
      def dispatch(mod), do: mod.unsure_entry(1)
    end
    """,
    "/chain/lib/chain/maybe.ex" => """
    defmodule Chain.Maybe do
      def unsure_entry(x), do: Chain.Maybe.only_from_unsure(x)
      def only_from_unsure(x), do: x
    end
    """
  }

  setup do
    ChunkCache.clear()
    GraphCache.clear()

    chunks =
      Enum.flat_map(@sources, fn {path, src} ->
        {:ok, entities} = Parser.parse_source(path, src)
        entities |> Chunker.chunk_entities() |> Enum.map(&Map.put(&1, :language, :elixir))
      end)

    ChunkCache.insert_many(chunks)
    GraphCache.rebuild_from_chunks(chunks)

    prev = Application.get_env(:elixir_nexus, :project_config)
    Application.delete_env(:elixir_nexus, :project_config)

    on_exit(fn ->
      ChunkCache.clear()
      GraphCache.clear()
      if prev, do: Application.put_env(:elixir_nexus, :project_config, prev)
    end)

    {:ok, result} = Queries.find_dead_code()
    {:ok, result: result}
  end

  defp qnames(entries), do: entries |> Enum.map(& &1.qualified_name) |> Enum.sort()
  defp via(result, qn), do: Enum.find(result.dead_via_dead_callers, &(&1.qualified_name == qn))

  test "a three-level chain: the top is dead, the two below are dead via dead callers", %{result: result} do
    assert "Chain.Top.top/1" in qnames(result.dead_functions)
    refute "Chain.Mid.mid/1" in qnames(result.dead_functions)

    assert %{dead_callers: ["Chain.Top.top/1"], chain: ["Chain.Top.top/1", "Chain.Mid.mid/1"]} =
             via(result, "Chain.Mid.mid/1")

    assert %{dead_callers: ["Chain.Mid.mid/1"], chain: ["Chain.Top.top/1", "Chain.Mid.mid/1", "Chain.Leaf.leaf/1"]} =
             via(result, "Chain.Leaf.leaf/1")
  end

  test "two dead functions calling each other are both dead via dead callers", %{result: result} do
    assert %{dead_callers: ["Chain.Cycle.pong/1"], chain: chain} = via(result, "Chain.Cycle.ping/1")
    assert List.first(chain) =~ "(cycle)"
    assert %{dead_callers: ["Chain.Cycle.ping/1"]} = via(result, "Chain.Cycle.pong/1")
    refute Enum.any?(result.dead_functions, &String.starts_with?(&1.qualified_name, "Chain.Cycle."))
  end

  test "a function calling itself at another arity is dead, not dead via itself", %{result: result} do
    assert "Chain.Defaults.walk/1" in qnames(result.dead_functions) or
             "Chain.Defaults.walk/2" in qnames(result.dead_functions)

    refute Enum.any?(result.dead_via_dead_callers, &String.starts_with?(&1.qualified_name, "Chain.Defaults."))
  end

  test "a chain through a private function", %{result: result} do
    assert "Chain.PrivateLink.entry_dead/1" in qnames(result.dead_functions)
    assert %{chain: chain} = via(result, "Chain.Target.through_private/1")
    assert List.first(chain) == "Chain.PrivateLink.entry_dead/1"
  end

  test "what a live root reaches is not dead, however long the chain", %{result: result} do
    all = qnames(result.dead_functions ++ result.dead_via_dead_callers ++ result.unsure)
    refute "Chain.Live.used/1" in all
    refute "Chain.Target.kept/1" in all
  end

  test "a function reached only from an unsure one stays unsure, not dead", %{result: result} do
    assert "Chain.Maybe.unsure_entry/1" in qnames(result.unsure)
    assert "Chain.Maybe.only_from_unsure/1" in qnames(result.unsure)
    refute via(result, "Chain.Maybe.only_from_unsure/1")
  end

  test "dead via dead callers is counted on its own", %{result: result} do
    assert result.dead_via_dead_callers_count == length(result.dead_via_dead_callers)
    assert result.dead_count == length(result.dead_functions)
    assert MapSet.disjoint?(MapSet.new(qnames(result.dead_functions)), MapSet.new(qnames(result.dead_via_dead_callers)))
  end

  test "a path prefix filters the report but not the graph", %{result: _} do
    {:ok, scoped} = Queries.find_dead_code(path_prefix: "/chain/lib/chain/leaf.ex")
    assert qnames(scoped.dead_via_dead_callers) == ["Chain.Leaf.leaf/1"]
    assert scoped.dead_functions == []
  end
end
