defmodule ElixirNexus.Search.ElixirCallIndexTest do
  @moduledoc """
  Exact Elixir matching in find_dead_code, find_all_callers, analyze_impact and
  find_all_callees, over entities the real parser produces from fixtures.
  """
  use ExUnit.Case, async: false

  alias ElixirNexus.{Chunker, ChunkCache, GraphCache, Parser}
  alias ElixirNexus.Search.Queries

  @sources %{
    "/proj/lib/my/a.ex" => """
    defmodule My.A do
      alias My.B
      def used(x), do: B.parse(x)
      def dead_one(x), do: x
      def parse(x), do: x
      def piped(x), do: x |> B.two(1)
      def recursive(0), do: 0
      def recursive(n), do: recursive(n - 1)
      def only_tested(x), do: x
      def short, do: helper()
      def helper, do: :ok
    end
    """,
    "/proj/lib/my/b.ex" => """
    defmodule My.B do
      def parse(x), do: x
      def two(x, y), do: {x, y}
      def two(x), do: x
    end
    """,
    "/proj/lib/my_web.ex" => """
    defmodule MyWeb do
      def live_view do
        quote do
          use Phoenix.LiveView
          unquote(html_helpers())
        end
      end

      def html do
        quote do
          unquote(html_helpers())
        end
      end

      defp html_helpers do
        quote do
          import My.Components
          alias My.Layouts
        end
      end

      defmacro __using__(which) when is_atom(which) do
        apply(__MODULE__, which, [])
      end
    end
    """,
    "/proj/lib/my/components.ex" => """
    defmodule My.Components do
      use Phoenix.Component
      def card(assigns), do: ~H"<div>{@x}</div>"
      def unused_comp(assigns), do: ~H"<div>{@x}</div>"
    end
    """,
    "/proj/lib/my/layouts.ex" => """
    defmodule My.Layouts do
      use Phoenix.Component
      def app(assigns), do: ~H"<main>{@inner}</main>"
    end
    """,
    "/proj/lib/my/page_live.ex" => ~S'''
    defmodule My.PageLive do
      use MyWeb, :live_view

      @impl true
      def render(assigns) do
        ~H"""
        <Layouts.app>
          <.card x={My.A.used(1)} />
        </Layouts.app>
        """
      end

      def go(mod), do: mod.handle(1)
      def go_short, do: My.A.short()
    end
    ''',
    "/proj/lib/my/handler.ex" => """
    defmodule My.Handler do
      def handle(x), do: x
    end
    """,
    "/proj/test/my/a_test.exs" => """
    defmodule My.ATest do
      use ExUnit.Case
      test "x" do
        My.A.only_tested(1)
      end
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

    on_exit(fn ->
      ChunkCache.clear()
      GraphCache.clear()

      if prev,
        do: Application.put_env(:elixir_nexus, :project_config, prev),
        else: Application.delete_env(:elixir_nexus, :project_config)
    end)

    Application.delete_env(:elixir_nexus, :project_config)
    :ok
  end

  defp dead_qnames(result), do: Enum.map(result.dead_functions, & &1.qualified_name)
  defp unsure_qnames(result), do: Enum.map(result.unsure, & &1.qualified_name)

  describe "find_dead_code" do
    test "a call to B.parse does not keep A.parse alive" do
      {:ok, result} = Queries.find_dead_code()
      assert "My.A.parse/1" in dead_qnames(result)
      refute "My.B.parse/1" in dead_qnames(result)
    end

    test "arity matters: two/2 is called, two/1 is not" do
      {:ok, result} = Queries.find_dead_code()
      assert "My.B.two/1" in dead_qnames(result)
      refute "My.B.two/2" in dead_qnames(result)
    end

    test "a function that only calls itself is dead" do
      {:ok, result} = Queries.find_dead_code()
      assert "My.A.recursive/1" in dead_qnames(result)
    end

    test "a function called from a one-line function is alive" do
      {:ok, result} = Queries.find_dead_code()
      refute "My.A.helper/0" in dead_qnames(result)
    end

    test "components used in HEEx through use-injected imports and aliases are alive" do
      {:ok, result} = Queries.find_dead_code()
      dead = dead_qnames(result)
      refute "My.Components.card/1" in dead
      refute "My.Layouts.app/1" in dead
      refute "My.A.used/1" in dead
      assert "My.Components.unused_comp/1" in dead
    end

    test "use MyWeb, :live_view calls MyWeb.live_view/0" do
      {:ok, result} = Queries.find_dead_code()
      refute "MyWeb.live_view/0" in dead_qnames(result)
    end

    test "a function reached only by a dynamic call is unsure, with the reason, not dead" do
      {:ok, result} = Queries.find_dead_code()
      refute "My.Handler.handle/1" in dead_qnames(result)
      assert "My.Handler.handle/1" in unsure_qnames(result)
      entry = Enum.find(result.unsure, &(&1.qualified_name == "My.Handler.handle/1"))
      assert entry.reason =~ "?handle/1"
      # apply(__MODULE__, which, []) could reach any MyWeb function of arity 0.
      assert "MyWeb.html/0" in unsure_qnames(result)
      assert result.unsure_count == length(result.unsure)
    end

    test "@impl callbacks are not reported" do
      {:ok, result} = Queries.find_dead_code()
      refute "My.PageLive.render/1" in dead_qnames(result)
    end

    test "test callers count by default" do
      {:ok, result} = Queries.find_dead_code()
      refute "My.A.only_tested/1" in dead_qnames(result)
    end

    test "count_test_callers: false reports functions only tests call, marked as such" do
      {:ok, result} = Queries.find_dead_code(count_test_callers: false)
      entry = Enum.find(result.dead_functions, &(&1.qualified_name == "My.A.only_tested/1"))
      assert entry
      assert entry.called_from_tests
      dead_one = Enum.find(result.dead_functions, &(&1.qualified_name == "My.A.dead_one/1"))
      refute dead_one.called_from_tests
    end

    test ".nexus.toml [dead_code] count_test_callers = false is the default for the project" do
      cfg = ElixirNexus.ProjectConfig.parse("[dead_code]\ncount_test_callers = false\n")
      Application.put_env(:elixir_nexus, :project_config, {"/proj", cfg})
      {:ok, result} = Queries.find_dead_code()
      assert "My.A.only_tested/1" in dead_qnames(result)
      # The tool parameter wins over the file.
      {:ok, result} = Queries.find_dead_code(count_test_callers: true)
      refute "My.A.only_tested/1" in dead_qnames(result)
    end

    test "each function is reported once, however many clauses it has" do
      {:ok, result} = Queries.find_dead_code()
      assert Enum.count(dead_qnames(result), &(&1 == "My.A.recursive/1")) == 1
    end
  end

  describe "find_all_callers" do
    test "a qualified query returns only that function's callers" do
      {:ok, callers} = Queries.find_callers("My.B.parse")
      assert Enum.map(callers, & &1.entity["qualified_name"]) == ["My.A.used/1"]
    end

    test "a short name returns the callers of every definition, each saying which one" do
      {:ok, callers} = Queries.find_callers("parse")
      assert Enum.map(callers, & &1.entity["resolves_to"]) == ["My.B.parse/1"]
    end

    test "callers through HEEx and injected aliases are found" do
      {:ok, callers} = Queries.find_callers("My.Layouts.app")
      assert Enum.map(callers, & &1.entity["qualified_name"]) == ["My.PageLive.render/1"]
    end

    test "dynamic callers are listed as fallback matches" do
      {:ok, callers} = Queries.find_callers("My.Handler.handle")
      assert [%{entity: %{"qualified_name" => "My.PageLive.go/1", "match" => "fallback"}}] = callers
    end
  end

  describe "analyze_impact" do
    test "walks qualified callers transitively" do
      {:ok, result} = Queries.analyze_impact("My.A.helper", 3)
      assert [%{name: "My.A.short/0", affected_by: [%{name: "My.PageLive.go_short/0"}]}] = result.impact
    end
  end

  describe "find_all_callees" do
    test "callees resolve to the exact definitions" do
      {:ok, callees} = Queries.find_callees("My.A.used")
      assert [%{entity: %{"file_path" => "/proj/lib/my/b.ex", "qualified_name" => "My.B.parse/1"}}] = callees
    end
  end
end
