---
name: nexus-parser-extractor
description: ElixirNexus polyglot parser/extractor architecture — Sourceror for Elixir, Tree-sitter (via Rust NIF) for JS/TS/Python/Go/Rust/Java/Ruby/Kotlin/Swift. Use when adding support for a new language, debugging missing entities/calls in extracted output, or understanding the chunking pipeline.
---

# Parser / Extractor Architecture

Source files come in many shapes; the indexing pipeline normalizes them to a single chunk format. Two parser families:

| Family | Languages | Module |
|--------|-----------|--------|
| Sourceror | Elixir (`.ex`, `.exs`) | `ElixirNexus.Parser` → `ElixirNexus.RelationshipExtractor` |
| Tree-sitter (Rust NIF) | JS, TS, JSX, TSX, Python, Go, Rust, Java, Ruby, Kotlin, Swift | `ElixirNexus.TreeSitterParser` → language-specific extractors |

Without the Rust toolchain, only Elixir files are indexed. The NIF binary lives at `priv/native/tree_sitter_nif.so`.

## Extractor pattern

Each language extractor takes parsed AST nodes from the NIF and emits **chunks** — maps with a stable shape (file_path, entity_type, name, content, start_line, end_line, calls, parameters, is_a, contains, language).

```
lib/elixir_nexus/parsers/
  ├ relationship_extractor.ex      # Elixir (Sourceror)
  ├ javascript_extractor.ex        # facade — delegates to:
  │   javascript/{entities,calls,imports_exports}.ex
  ├ python_extractor.ex            # entities + calls + imports + decorators
  ├ go_extractor.ex                # facade — delegates to:
  │   go/{entities,calls,imports_package}.ex
  ├ rust_extractor.ex              # use imports, impl hierarchy, pub visibility, name! macros
  ├ java_extractor.ex              # scoped imports, method_invocation, supertypes, modifiers
  └ generic_extractor.ex           # fallback for Ruby, Kotlin, Swift
```

JS/TS and Go split their work into sub-modules (entities, calls, imports). Single-file extractors (Python, Rust, Java) keep everything in one module — pick the layout that matches the size of the language's surface.

## Adding a new language

1. **Tree-sitter NIF**: in `native/tree_sitter_nif/src/lib.rs`, add a `tree_sitter_<lang>` dependency in `Cargo.toml`, register the language, and add its node types to `is_significant_node`. The CLAUDE.md "Tree-sitter NIF depth limits" section has the full node-type list per language. **Critical:** untracked node types get filtered out at depth 20/25.
2. **File extension mapping**: add to `IndexingHelpers.@polyglot_extensions` so the dispatcher routes the file.
3. **Extractor**: create `lib/elixir_nexus/parsers/<lang>_extractor.ex` (facade) + sub-modules under `parsers/<lang>/`. Implement:
   - `extract_entities/2` — modules, classes, functions, methods
   - `extract_calls/2` — function/method calls
   - `extract_imports/2` — language-specific import syntax
4. **Wire into dispatch**: add a case in `IndexingHelpers.process_file/1` and `parse_with_tree_sitter/2`.
5. **Tests**: 3 test files matching the sub-modules — `<lang>_entities_test.exs`, `<lang>_calls_test.exs`, `<lang>_imports_test.exs` (or similar). See `test/elixir_nexus/parsers/go_*_test.exs` for the pattern.
6. **Source dirs**: if the language has its own convention (Go's `cmd/`/`internal/`/`pkg/`, Rust's `src/`), add to `IndexingHelpers.@indexable_dirs`.

## Chunk shape

Every chunk is a map. Required keys:
- `file_path` (string, container path like `/workspace/foo/bar.ex`)
- `entity_type` (atom: `:module`, `:function`, `:class`, `:method`, `:interface`, etc.)
- `name` (string, fully qualified where reasonable)
- `content` (string, source text used for embedding)
- `start_line`, `end_line` (integers, 1-indexed)
- `language` (atom: `:elixir`, `:javascript`, `:python`, `:go`, ...)

Optional keys (always use `Map.get` to read — see nexus-search-subsystem for why):
- `calls` (list of strings — names of called functions/methods)
- `parameters` (list of strings — parameter names)
- `is_a` (list of strings — behaviours/superclasses/interfaces; e.g. `["GenServer"]`, `["directive:use-server"]`)
- `contains` (list of strings — child entity names)
- `module_path` (string — namespace path)
- `visibility` (atom: `:public`, `:private`)

## Tree-sitter NIF gotchas

- **`skip_compilation?: true`** is the default in `tree_sitter_parser.ex` so tests don't need Rust. The NIF is loaded from `priv/native/tree_sitter_nif.so` via `load_from`.
- **To rebuild after Rust source changes**: temporarily set `skip_compilation?: false`, run `PATH="$HOME/.cargo/bin:$PATH" mix compile --force`, then revert. The Dockerfile does this automatically for Linux builds.
- **Rustler version must match the NIF crate**: `Cargo.toml` `rustler = "0.37"` ↔ Elixir dep `{:rustler, "~> 0.37"}`.
- **Depth limits (20/25)**: deeply nested constructs may be silently truncated. If extraction misses something deep in a tree, check `lib.rs` first.

## Common pitfalls

- **Entity type as atom vs string** — chunks store atoms (`:function`); search payloads serialize to strings (`"function"`). The Resources/GraphStats path uses `node["entity_type"] || node["type"]` to handle both. Don't break this.
- **JSX/TSX call edges** — `<Button />` is a call edge in v0.4+; the NIF has special handling. Don't filter JSX nodes out at the extractor level.
- **Generic extractor is the fallback** — for languages without a dedicated extractor, `GenericExtractor` produces basic entity + import data. Ruby, Kotlin, and Swift currently use this. Rust and Java were promoted out of generic in v1.10.0 once the cost of basic-only output (no calls, no impl-method names) outweighed the cost of writing a dedicated extractor. Migrate when the generic output isn't useful for the language's idioms.
- **Tree-sitter parse errors fail the whole file** — Broadway's `handle_failed/2` acks the file with an error; it doesn't crash the pipeline. Check `[:nexus, :pipeline, :file_error]` telemetry events for diagnostics.
