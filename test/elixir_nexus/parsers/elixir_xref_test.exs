defmodule ElixirNexus.Parsers.ElixirXrefTest do
  @moduledoc """
  Elixir calls resolve to `Module.fun/arity` at parse time: aliases, nested
  modules, pipes, captures, HEEx components, delegates. Each test names the
  behaviour it pins.
  """
  use ExUnit.Case, async: true

  alias ElixirNexus.Parser

  defp parse(src, path \\ "lib/fixture.ex") do
    {:ok, entities} = Parser.parse_source(path, src)
    entities
  end

  defp fun(entities, name) do
    Enum.find(entities, &(&1.entity_type in [:function, :macro] and &1.name == name)) ||
      flunk("no function #{name} in #{inspect(Enum.map(entities, & &1.name))}")
  end

  defp mod(entities, name), do: Enum.find(entities, &(&1.entity_type == :module and &1.name == name))

  defp calls(entities, name), do: fun(entities, name).xref["calls"]

  describe "aliases" do
    test "a call through an alias resolves to the full module and its arity" do
      src = """
      defmodule Contra.Web.Page do
        alias Contra.Runs
        def show(id), do: Runs.start(id, [])
      end
      """

      assert "Contra.Runs.start/2" in calls(parse(src), "show")
    end

    test "multi-alias, as:, __MODULE__ and alias __MODULE__.Sub" do
      src = """
      defmodule A.Mod do
        alias A.{B, C.D}
        alias A.Long.Name, as: Short
        alias __MODULE__.Sub
        def f do
          B.one()
          D.two(1)
          Short.three(1, 2)
          Sub.four()
          __MODULE__.five()
        end
        def five, do: :ok
      end
      """

      calls = calls(parse(src), "f")
      assert "A.B.one/0" in calls
      assert "A.C.D.two/1" in calls
      assert "A.Long.Name.three/2" in calls
      assert "A.Mod.Sub.four/0" in calls
      assert "A.Mod.five/0" in calls
    end

    test "an alias defined after another expands through it" do
      src = """
      defmodule A do
        alias Contra.Engine
        alias Engine.Spec
        def f, do: Spec.new()
      end
      """

      assert "Contra.Engine.Spec.new/0" in calls(parse(src), "f")
    end
  end

  describe "local and imported calls" do
    test "a bare call to a function the module defines resolves to the module" do
      src = """
      defmodule M do
        def a(x), do: b(x)
        def b(x), do: x
      end
      """

      assert calls(parse(src), "a") == ["M.b/1"]
    end

    test "a bare call the module does not define stays bare with its arity, Kernel calls are dropped" do
      src = """
      defmodule M do
        import Other
        def a(x) do
          if is_nil(x), do: to_string(x), else: helper(x, 1)
        end
      end
      """

      assert calls(parse(src), "a") == ["helper/2"]
    end

    test "a pipe adds one to the arity of the call on its right" do
      src = """
      defmodule M do
        alias X.Y
        def a(x), do: x |> Y.go(1) |> b()
        def b(x), do: x
      end
      """

      calls = calls(parse(src), "a")
      assert "X.Y.go/2" in calls
      assert "M.b/1" in calls
    end

    test "default arguments give a function one qualified name per arity" do
      src = """
      defmodule M do
        def a(x, y \\\\ 1, z \\\\ 2), do: {x, y, z}
      end
      """

      assert fun(parse(src), "a").xref["qualified_names"] == ["M.a/1", "M.a/2", "M.a/3"]
    end

    test "guarded and paren-less heads get their arity" do
      src = """
      defmodule M do
        def a(x) when is_integer(x), do: x
        def b, do: :ok
      end
      """

      entities = parse(src)
      assert fun(entities, "a").xref["qualified_names"] == ["M.a/1"]
      assert fun(entities, "b").xref["qualified_names"] == ["M.b/0"]
    end

    test "imports are recorded on the module, expanded through aliases" do
      src = """
      defmodule M do
        alias Contra.Web
        import Web.Helpers, only: [x: 1]
        use Contra.Base, :live_view
        @behaviour Contra.Behaviour
        def a, do: :ok
      end
      """

      xref = mod(parse(src), "M").xref
      assert xref["imports"] == ["Contra.Web.Helpers"]
      assert xref["uses"] == ["Contra.Base"]
      assert xref["behaviours"] == ["Contra.Behaviour"]
      # `use Mod, :which` dispatches to Mod.which/0 (the Phoenix `use MyAppWeb, :live_view` convention).
      assert "Contra.Base.live_view/0" in xref["calls"]
    end
  end

  describe "function references" do
    test "captures are calls with the captured arity" do
      src = """
      defmodule M do
        alias X.Y
        def a(list), do: Enum.map(list, &Y.go/1) ++ Enum.map(list, &b/1) ++ Enum.map(list, &Y.two(&1, 2))
        def b(x), do: x
      end
      """

      calls = calls(parse(src), "a")
      assert "X.Y.go/1" in calls
      assert "M.b/1" in calls
      assert "X.Y.two/2" in calls
    end

    test "apply with a literal module and atom, and MFA tuples, are calls" do
      src = """
      defmodule M do
        alias X.Y
        def a(args) do
          apply(Y, :one, [1, 2])
          apply(Y, :two, args)
          :timer.apply_after(10, Y, :three, [])
          {Y, :four, [1]}
          {Y, :five}
        end
      end
      """

      calls = calls(parse(src), "a")
      assert "X.Y.one/2" in calls
      assert "X.Y.two/*" in calls
      # Erlang-style MFA arguments: the list gives the arity.
      assert "X.Y.three/0" in calls
      # A tuple names a function; its caller may add arguments.
      assert "X.Y.four/*" in calls
      assert "X.Y.five/*" in calls
    end

    test "MFA arguments and tuples with __MODULE__" do
      src = """
      defmodule M do
        def a(nodes), do: :erpc.multicall(nodes, __MODULE__, :count, [1, 2], 250)
        def child_spec(o), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [o]}}
        def count(a, b), do: {a, b}
        def start_link(o), do: o
      end
      """

      entities = parse(src)
      assert "M.count/2" in calls(entities, "a")
      assert "M.start_link/*" in calls(entities, "child_spec")
    end

    test "a module in a literal list or {Mod, arg} is a supervisor child: Mod.child_spec/1" do
      src = """
      defmodule App do
        def start(_t, _a) do
          children = [Contra.Repo, {Phoenix.PubSub, name: X}, {Task.Supervisor, :named}]
          Supervisor.start_link(children, strategy: :one_for_one)
        end
        def other, do: Contra.Thing.go(Contra.Arg)
      end
      """

      entities = parse(src)
      calls = calls(entities, "start")
      assert "Contra.Repo.child_spec/1" in calls
      assert "Phoenix.PubSub.child_spec/1" in calls
      refute "Task.Supervisor.child_spec/1" in calls
      # A module passed as an argument is not a child spec.
      refute "Contra.Arg.child_spec/1" in calls(entities, "other")
    end

    test "on_mount hooks call Mod.on_mount/4" do
      src = """
      defmodule MyRouter do
        def routes do
          live_session :app, on_mount: [{My.Scope, :default}, My.Auth] do
            :ok
          end
        end
      end
      defmodule MyLive do
        on_mount My.Hook
        def x, do: :ok
      end
      """

      entities = parse(src)
      calls = calls(entities, "routes")
      assert "My.Scope.on_mount/4" in calls
      assert "My.Auth.on_mount/4" in calls
      assert "My.Hook.on_mount/4" in mod(entities, "MyLive").xref["calls"]
    end

    test "a call on a variable is dynamic, a field access is not a call" do
      src = """
      defmodule M do
        def a(mod, map), do: mod.parse(map.field)
      end
      """

      assert calls(parse(src), "a") == ["?parse/1"]
    end

    test "apply on a variable module with a literal atom is dynamic" do
      src = """
      defmodule M do
        def a(mod), do: apply(mod, :parse, [1])
      end
      """

      assert calls(parse(src), "a") == ["?parse/1"]
    end

    test "defdelegate is a public function that calls its target" do
      src = """
      defmodule M do
        alias X.Y
        defdelegate go(a, b), to: Y
        defdelegate other(a), to: Y, as: :renamed
      end
      """

      entities = parse(src)
      go = fun(entities, "go")
      assert go.visibility == :public
      assert go.xref["qualified_names"] == ["M.go/2"]
      assert go.xref["calls"] == ["X.Y.go/2"]
      assert calls(entities, "other") == ["X.Y.renamed/1"]
    end

    test "plug :name calls name/2 of the module, or a bare name/2 to resolve through imports" do
      src = """
      defmodule MyController do
        import MyAuth
        plug :require_user
        plug :fetch_user
        def require_user(conn, _opts), do: conn
      end
      """

      calls = mod(parse(src), "MyController").xref["calls"]
      assert "MyController.require_user/2" in calls
      assert "fetch_user/2" in calls
    end

    test "render(conn, :name) in a controller calls the HTML module's template function" do
      src = """
      defmodule MyAppWeb.PageController do
        def home(conn, _params), do: render(conn, :home, layout: false)
      end
      """

      assert "MyAppWeb.PageHTML.home/1" in calls(parse(src), "home")
    end

    test "conn |> render(:name) in a controller renders the template too" do
      src = """
      defmodule MyAppWeb.AuthController do
        def deny(conn, _params), do: conn |> put_status(403) |> render(:denied, reason: :x)
      end
      """

      assert "MyAppWeb.AuthHTML.denied/1" in calls(parse(src), "deny")
    end
  end

  describe "modules" do
    test "functions of nested modules are entities with the nested module's name" do
      src = """
      defmodule Outer do
        defmodule Inner do
          def f, do: :ok
        end
        def g, do: Inner.f()
      end
      """

      entities = parse(src)
      f = fun(entities, "f")
      assert f.module_path == "Outer.Inner"
      assert f.xref["qualified_names"] == ["Outer.Inner.f/0"]
      assert mod(entities, "Outer.Inner")
      # Nested modules are aliased in their parent.
      assert calls(entities, "g") == ["Outer.Inner.f/0"]
    end

    test "@impl marks the following function as a callback, all its clauses" do
      src = """
      defmodule M do
        @impl true
        def handle_info(:a, s), do: s
        def handle_info(:b, s), do: s
        def other(x), do: x
      end
      """

      entities = parse(src)
      callbacks = entities |> Enum.filter(&(&1.name == "handle_info")) |> Enum.map(& &1.xref["callback"])
      assert callbacks == [true, true]
      refute fun(entities, "other").xref["callback"]
    end

    test "imports and aliases inside quote blocks are what `use` injects" do
      src = """
      defmodule MyWeb do
        def live_view do
          quote do
            unquote(helpers())
          end
        end
        defp helpers do
          quote do
            import MyWeb.CoreComponents
            alias MyWeb.Layouts
            use MyWeb.Gettext
          end
        end
      end
      """

      injects = mod(parse(src), "MyWeb").xref["injects"]
      assert injects["imports"] == ["MyWeb.CoreComponents"]
      assert injects["aliases"] == %{"Layouts" => "MyWeb.Layouts"}
      assert injects["uses"] == ["MyWeb.Gettext"]
    end

    test "module-level calls belong to the module, not to the functions" do
      src = """
      defmodule M do
        @data X.load()
        def a, do: :ok
      end
      """

      entities = parse(src)
      assert mod(entities, "M").xref["calls"] == ["X.load/0"]
      assert calls(entities, "a") == []
    end

    test "calls in use options are calls" do
      src = """
      defmodule M do
        use Lib.Component, type: :tool, annotations: My.Tool.annotations(:x, [])
      end
      """

      assert "My.Tool.annotations/2" in mod(parse(src), "M").xref["calls"]
    end

    test "typespecs are not calls" do
      src = """
      defmodule M do
        @spec a(String.t()) :: Foo.t()
        def a(x), do: x
      end
      """

      assert mod(parse(src), "M").xref["calls"] == []
    end
  end

  describe "HEEx" do
    test "components and expressions in ~H are calls" do
      src = ~S'''
      defmodule MyWeb.Page do
        alias MyWeb.Layouts
        def render(assigns) do
          ~H"""
          <Layouts.app flash={@flash}>
            <.card title={label(@x)}>
              <%= for r <- @rows do %>{Fmt.cell(r)}<% end %>
            </.card>
          </Layouts.app>
          """
        end
        def label(x), do: x
      end
      '''

      calls = calls(parse(src), "render")
      assert "MyWeb.Layouts.app/1" in calls
      assert "card/1" in calls
      assert "MyWeb.Page.label/1" in calls
      assert "Fmt.cell/1" in calls
    end

    test "a .heex template is the embedding module's function of the same name" do
      dir = Path.join(System.tmp_dir!(), "xref_heex_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "page_html"))
      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(Path.join(dir, "page_html.ex"), """
      defmodule MyWeb.PageHTML do
        use MyWeb, :html
        embed_templates "page_html/*"
        def title(x), do: x
      end
      """)

      path = Path.join(dir, "page_html/home.html.heex")

      File.write!(path, ~S"""
      <.header>{title(@t)}</.header>
      """)

      {:ok, [template]} = Parser.parse_template(path)
      assert template.entity_type == :function
      assert template.name == "home"
      assert template.module_path == "MyWeb.PageHTML"
      assert template.xref["qualified_names"] == ["MyWeb.PageHTML.home/1"]
      assert "header/1" in template.xref["calls"]
      assert "MyWeb.PageHTML.title/1" in template.xref["calls"]
    end
  end
end
