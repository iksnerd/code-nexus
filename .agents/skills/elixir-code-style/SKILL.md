---
name: elixir-code-style
description: Elixir code style, naming conventions, and idiomatic patterns. Use when writing any Elixir code, reviewing style, choosing between approaches, or when asked about naming, pipe operators, pattern matching, error tuples, or functional design principles.
metadata:
  source: cursor.directory community rules + ElixirNexus codebase
---

# Elixir Code Style

## Naming Conventions

- `snake_case` for files, functions, variables, module attributes
- `PascalCase` for modules (e.g. `MyApp.UserContext`)
- Predicate functions end with `?`, never start with `is_` (that prefix is for guards): `valid?/1`, not `is_valid/1`
- Guards use `is_` prefix: `is_binary/1`, `is_map/1`
- Name functions descriptively: `calculate_total_price/2` not `calc/2`

## Pattern Matching

Prefer pattern matching over conditional logic everywhere:

```elixir
# Good — pattern match on function heads
def process(%{status: :ok, data: data}), do: handle_data(data)
def process(%{status: :error, reason: reason}), do: handle_error(reason)

# Avoid
def process(result) do
  if result.status == :ok do
    handle_data(result.data)
  else
    handle_error(result.reason)
  end
end
```

- Avoid nested `case` — refactor to a single `case`, `with`, or separate function clauses
- `%{}` matches **any** map, not just empty ones. Use `map_size(map) == 0` to check for truly empty maps

## Pipe Operator

Chain transformations with `|>` for readability:

```elixir
# Good
result =
  raw_data
  |> parse()
  |> validate()
  |> transform()

# Avoid
result = transform(validate(parse(raw_data)))
```

## Error Handling

- Use `{:ok, result}` / `{:error, reason}` tuples at all system boundaries
- Use `with` to chain fallible operations cleanly:

```elixir
with {:ok, user} <- fetch_user(id),
     {:ok, order} <- fetch_order(user),
     {:ok, result} <- process(order) do
  {:ok, result}
end
```

- Raise exceptions only for programmer errors (unexpected state), not expected failures
- No early returns — Elixir has none. Last expression in a block is the return value

## Data Structures

- **Structs** over maps when the shape is known: `defstruct [:name, :age]`
- **Keyword lists** for options: `[timeout: 5000, retries: 3]`
- **Maps** for dynamic key-value data
- Prepend to lists: `[new | list]` — never `list ++ [new]` (O(n) cost)
- Lists and enumerables cannot be indexed with `[]` — use pattern matching or `Enum` functions

## Function Design

- Use guard clauses for input validation: `when is_binary(name) and byte_size(name) > 0`
- Prefer multiple function clauses over complex conditional logic inside one function
- Prefer `Enum` functions like `Enum.reduce/3` over manual recursion
- When recursion is necessary, use pattern matching in function heads for the base case
- Only use macros if explicitly requested

## Common Mistakes to Avoid

- No `return` statement. Last expression always returned.
- Don't use `String.to_atom/1` on user input (atoms are never GC'd — memory leak)
- Don't use `Enum` on large lazy collections — prefer `Stream`
- Avoid the process dictionary (`:erlang.put/2`) — it's unidiomatic; use GenServer state or ETS

## Code Quality Tools

Run before committing:
```bash
mix compile --warnings-as-errors   # Zero warnings required
mix format --check-formatted       # Auto-fix with: mix format
mix credo --strict                 # Linting
```

Optional:
```bash
mix sobelow                        # Security analysis
mix dialyzer                       # Type checking (slow, run in CI)
```
