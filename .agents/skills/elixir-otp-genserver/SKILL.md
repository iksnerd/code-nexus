---
name: elixir-otp-genserver
description: GenServer patterns for stateful processes in OTP. Use when implementing a GenServer, designing stateful process behavior, choosing between call/cast/info, handling process lifecycle, or debugging a GenServer. Also covers handle_continue, terminate, and client API wrapping.
metadata:
  source: hexdocs.pm/elixir/GenServer + usage_rules/:otp
  docs: https://hexdocs.pm/elixir/GenServer.html
---

# GenServer Patterns

## Basic Structure

```elixir
defmodule MyApp.Counter do
  use GenServer

  # Client API — public interface wraps GenServer calls
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts[:initial] || 0, name: opts[:name] || __MODULE__)
  end

  def increment(pid \\ __MODULE__), do: GenServer.cast(pid, :increment)
  def get(pid \\ __MODULE__), do: GenServer.call(pid, :get)

  # Server callbacks
  @impl true
  def init(initial), do: {:ok, initial}

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast(:increment, state), do: {:noreply, state + 1}

  @impl true
  def handle_info(:tick, state) do
    # Handle messages sent via Process.send/send_after
    {:noreply, state}
  end
end
```

## call vs cast vs info

| Mechanism | Use when | Guarantees reply? |
|---|---|---|
| `GenServer.call/3` | Need a response; back-pressure needed | Yes (blocks caller) |
| `GenServer.cast/2` | Fire-and-forget; no reply needed | No |
| `handle_info/2` | External messages (timers, PubSub, monitors) | N/A |

**Default to `call` over `cast`** — it provides back-pressure and easier debugging.

## State Design

Keep state simple and serializable:

```elixir
# Good — plain map with atom keys
def init(_opts) do
  {:ok, %{count: 0, errors: [], status: :idle}}
end

# Avoid — complex nested structs, PIDs in state without monitoring
```

## Post-Init Work with handle_continue

Use `handle_continue/2` for work that should happen after `init/1` returns (avoids blocking the supervisor):

```elixir
def init(opts) do
  {:ok, %{}, {:continue, {:setup, opts}}}
end

def handle_continue({:setup, opts}, state) do
  new_state = do_expensive_setup(opts)
  {:noreply, new_state}
end
```

## Process Naming

```elixir
# Module name (single global instance)
GenServer.start_link(__MODULE__, state, name: __MODULE__)

# Atom name
GenServer.start_link(__MODULE__, state, name: :my_worker)

# Via Registry (dynamic named processes)
GenServer.start_link(__MODULE__, state,
  name: {:via, Registry, {MyApp.Registry, key}})
```

## Timeouts

```elixir
# Call timeout (default 5000ms — raise if server doesn't reply)
GenServer.call(pid, :work, 30_000)

# Idle timeout — server receives :timeout message after inactivity
def handle_call(:work, _from, state) do
  {:reply, :ok, state, 60_000}  # 60s idle timeout
end

def handle_info(:timeout, state) do
  # Clean up idle state
  {:noreply, state}
end
```

Always set appropriate timeouts for call operations. Default 5s is too short for I/O-bound work.

## Cleanup with terminate

```elixir
@impl true
def terminate(reason, state) do
  # Called when process is about to exit
  # Only called if process is trapping exits: Process.flag(:trap_exit, true)
  cleanup(state)
  :ok
end
```

## Debugging

```elixir
# Inspect GenServer state at runtime
:sys.get_state(pid)
:sys.get_state(__MODULE__)

# Trace messages
:sys.trace(pid, true)
```

## Common Mistakes

- Don't do blocking I/O in `handle_call` without setting a longer timeout
- Don't store large data in state — use ETS for hot-path reads
- Don't call your own GenServer from within a callback (deadlock)
- `terminate/2` is not called unless the process traps exits — don't rely on it for critical cleanup
