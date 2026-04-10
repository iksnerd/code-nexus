---
name: nexus-rustler-nif
description: ElixirNexus Rustler NIF build workflow for the tree-sitter parser. Use when modifying Rust NIF source, rebuilding the NIF locally or for Docker, understanding skip_compilation? and load_from patterns, or debugging NIF loading failures.
metadata:
  compatibility: ElixirNexus project only — native/tree_sitter_nif/ and lib/elixir_nexus/tree_sitter_parser.ex
---

# ElixirNexus Rustler NIF

## Key Files

| File | Role |
|---|---|
| `lib/elixir_nexus/tree_sitter_parser.ex` | Elixir NIF wrapper with skip_compilation? pattern |
| `native/tree_sitter_nif/src/lib.rs` | Rust NIF implementation — parsing + AST filtering |
| `native/tree_sitter_nif/Cargo.toml` | Rust dependencies (rustler = "0.37") |
| `priv/native/tree_sitter_nif.so` | Pre-compiled macOS NIF binary (committed) |

## CRITICAL: Must Compile via Mix, Not cargo

The NIF must be compiled **through Mix** (`mix compile`), never via raw `cargo build`. Mix provides the correct ERTS NIF ABI linking. A NIF compiled with raw cargo will fail to load with a cryptic ABI mismatch error.

```bash
# CORRECT — compiles with proper ERTS linking
PATH="$HOME/.cargo/bin:$PATH" mix compile --force

# WRONG — produces wrong ABI, will crash at runtime
cd native/tree_sitter_nif && cargo build --release
```

## Rebuilding the NIF (local macOS)

When Rust source changes:

```bash
# 1. Enable compilation in tree_sitter_parser.ex:
#    Remove: skip_compilation?: true
#    Remove: load_from: {:elixir_nexus, "priv/native/tree_sitter_nif"}

# 2. Compile
PATH="$HOME/.cargo/bin:$PATH" mix compile --force

# 3. Restore skip_compilation? in tree_sitter_parser.ex:
#    Add back: skip_compilation?: true, load_from: {:elixir_nexus, "priv/native/tree_sitter_nif"}

# 4. Restart the server
```

## skip_compilation? Pattern

The current state in `tree_sitter_parser.ex`:

```elixir
use Rustler,
  otp_app: :elixir_nexus,
  crate: :tree_sitter_nif,
  skip_compilation?: true,              # Don't recompile on `mix compile`
  load_from: {:elixir_nexus, "priv/native/tree_sitter_nif"}  # Load pre-built .so
```

This means:
- `mix compile` loads the pre-built `.so` from `priv/native/` — no Rust toolchain needed
- Tests run without Rust/Cargo in PATH
- Docker doesn't need to re-compile the NIF unless Rust source changed

## Docker NIF Build

The Dockerfile automatically handles Linux NIF compilation:
1. Deletes the macOS `.so` (wrong ABI for Linux)
2. Temporarily sets `skip_compilation?: false` via `sed`
3. Runs `mix compile --force` (compiles Linux NIF)
4. Restores `skip_compilation?: true`

No manual steps needed — just rebuild the Docker image after Rust source changes:

```bash
docker-compose build elixir_nexus
```

## Graceful Fallback

When the NIF can't be loaded, parsing falls back to Elixir-based sourceror:

```elixir
def parse(file, language) do
  if Code.ensure_loaded?(__MODULE__.Native) do
    __MODULE__.Native.parse(file, language)
  else
    {:error, :nif_not_loaded}
  end
end
```

## Adding Node Types (Rust source)

When adding support for new languages or AST node types, update `is_significant_node()` in `native/tree_sitter_nif/src/lib.rs`:

```rust
fn is_significant_node(kind: &str) -> bool {
  matches!(kind,
    // existing types...
    | "your_new_node_type"
  )
}
```

Then rebuild the NIF (see above). Node types not in `is_significant_node` are filtered from the AST output. The NIF has depth limits (20/25 levels) to prevent stack overflow on deeply nested ASTs.

## Version Pinning

`rustler = "0.37"` in `Cargo.toml` must match the Elixir dep `{:rustler, "~> 0.37"}` in `mix.exs`. Mismatched versions cause ABI errors at load time. Check both when upgrading.
