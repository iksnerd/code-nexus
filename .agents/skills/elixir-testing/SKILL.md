---
name: elixir-testing
description: ExUnit testing patterns for Elixir, including async strategy, Mox for behaviour mocking, test tags, database sandbox isolation, and performance benchmarking. Use when writing tests, setting up Mox mocks, choosing async: true or false, or structuring test modules.
metadata:
  source: hexdocs.pm/ex_unit + ElixirNexus codebase
  docs: https://hexdocs.pm/ex_unit/ExUnit.html
---

# Elixir Testing with ExUnit

## async: true vs async: false

```elixir
# async: true — test module runs concurrently with others
# Safe when: tests have no shared mutable state (no Registry, PubSub, ETS, DB)
defmodule MyApp.PureLogicTest do
  use ExUnit.Case, async: true

  test "calculates correctly" do
    assert MyApp.Calculator.add(1, 2) == 3
  end
end

# async: false — test module runs alone (serialized)
# Required when: tests use Registry, PubSub, global ETS, or named GenServers
defmodule MyApp.EventsTest do
  use ExUnit.Case, async: false

  test "broadcasts events" do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "topic")
    MyApp.Events.broadcast(:something)
    assert_receive {:something}
  end
end
```

## Running Tests

```bash
mix test                              # All tests
mix test test/my_module_test.exs      # Single file
mix test test/my_test.exs:42          # Single test by line number
mix test --trace                      # Verbose output
mix test --max-failures 3             # Stop after 3 failures
mix test --only performance           # Only @tag :performance tests
mix test --exclude performance        # Skip performance tests
mix test --include integration        # Include @tag :integration tests
```

## Test Tags

```elixir
defmodule MyApp.PerformanceTest do
  use ExUnit.Case, async: false

  @moduletag :performance       # Tag entire module

  @tag :slow
  test "processes 10k items" do
    # ...
  end
end
```

## Mox — Behaviour Mocking

Mox enforces that mocks implement a behaviour contract.

**Setup** (`test/support/mocks.ex`):
```elixir
Mox.defmock(MockQdrant, for: MyApp.QdrantBehaviour)
Mox.defmock(MockSearch, for: MyApp.SearchBehaviour)
```

**In test**:
```elixir
defmodule MyApp.IndexerTest do
  use ExUnit.Case, async: true
  import Mox

  setup :verify_on_exit!   # Ensures all expected calls were made

  test "indexes a file" do
    MockQdrant
    |> expect(:upsert_points, fn points -> {:ok, length(points)} end)
    |> stub(:health_check, fn -> :ok end)

    assert {:ok, _} = MyApp.Indexer.index_file("lib/foo.ex")
  end
end
```

- `expect/3` — must be called exactly N times (default 1)
- `stub/3` — can be called any number of times
- `allow/3` — share mock expectations across processes (needed for async)

**Inject mock via application config** (not module attribute):
```elixir
# config/test.exs
config :my_app, qdrant_client: MockQdrant

# In code
qdrant = Application.get_env(:my_app, :qdrant_client, MyApp.QdrantClient)
```

## Database Sandbox (Ecto)

```elixir
# test_helper.exs
Ecto.Adapters.SQL.Sandbox.mode(MyApp.Repo, :manual)

# In test
defmodule MyApp.UserTest do
  use MyApp.DataCase    # sets up sandbox checkout

  test "creates user" do
    assert {:ok, user} = MyApp.Accounts.create_user(%{name: "Alice"})
    assert user.name == "Alice"
  end
end
```

## Assertions

```elixir
# Value assertions
assert result == {:ok, 42}
refute result == {:error, _}

# Pattern matching assertions
assert {:ok, %{name: "Alice"} = user} = MyApp.create_user(params)

# Process message assertions
assert_receive {:event, :done}, 1000   # wait up to 1000ms
refute_receive {:error, _}, 100        # ensure no error message in 100ms

# Exception assertions
assert_raise ArgumentError, fn -> MyApp.bad_call() end
assert_raise ArgumentError, ~r/invalid/, fn -> MyApp.bad_call() end

# Approximate equality
assert_in_delta result, 3.14, 0.01
```

## Performance Testing Pattern (from ElixirNexus)

```elixir
defmodule MyApp.PerformanceTest do
  use ExUnit.Case, async: false
  @moduletag :performance

  defp measure(fun) do
    {micros, result} = :timer.tc(fun)
    {result, micros / 1000}  # return ms
  end

  defp assert_under(actual_ms, max_ms) do
    assert actual_ms < max_ms,
      "Expected under #{max_ms}ms but took #{Float.round(actual_ms, 2)}ms"
  end

  test "search completes in under 50ms" do
    {_result, ms} = measure(fn -> MyApp.Search.search("query") end)
    assert_under(ms, 50)
  end

  test "statistical benchmark" do
    times = for _ <- 1..100, do: elem(measure(fn -> MyApp.fast_op() end), 1)
    p95 = Enum.sort(times) |> Enum.at(round(100 * 0.95) - 1)
    assert_under(p95, 10)
  end
end
```

## Common Mistakes

- Using `async: true` with shared named processes or ETS causes flaky tests
- Forgetting `verify_on_exit!` with Mox — expected calls go unverified
- Using `assert_receive` without a timeout — default is 100ms which can be flaky in CI
- Not flushing mailbox between tests when using PubSub: add `flush_mailbox()` helper
