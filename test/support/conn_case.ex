defmodule ElixirNexus.ConnCase do
  @moduledoc """
  Test case for tests that require a connection (Phoenix controllers and LiveViews).
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest

      @endpoint ElixirNexus.Endpoint
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
