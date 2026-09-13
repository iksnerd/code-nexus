# Language support

[← Back to the README](../README.md)

Elixir files are parsed with Sourceror, which exposes macro and module metadata that Tree-sitter doesn't. Every other language goes through Tree-sitter via a Rustler NIF (`native/tree_sitter_nif`) and a language-specific extractor.

| Language | Extensions | Parser | Extractor |
|----------|------------|--------|-----------|
| Elixir | `.ex`, `.exs` | Sourceror | RelationshipExtractor |
| JavaScript | `.js`, `.jsx`, `.mjs` | Tree-sitter | JavaScriptExtractor |
| TypeScript | `.ts`, `.tsx` | Tree-sitter | JavaScriptExtractor |
| Python | `.py` | Tree-sitter | PythonExtractor |
| Go | `.go` | Tree-sitter | GoExtractor |
| Rust | `.rs` | Tree-sitter | RustExtractor |
| Java | `.java` | Tree-sitter | JavaExtractor |
| Ruby | `.rb` | Tree-sitter | GenericExtractor |
| Kotlin | `.kt`, `.kts` | Tree-sitter | GenericExtractor |
| Swift | `.swift` | Tree-sitter | GenericExtractor |

## Extractor capabilities

| Feature | JS/TS | Python | Go | Rust | Java | Generic (Ruby/Kotlin/Swift) |
|---------|-------|--------|----|------|------|---------|
| Functions/classes/methods | Y | Y | Y | Y | Y | Y |
| Import extraction | Y | Y | Y | Y | Y | partial |
| Export extraction | Y | - | - | - | - | - |
| Decorator extraction | - | Y | - | - | - | - |
| Call graph | Y | Y | Y | Y | Y | partial |
| Package-qualified calls | Y | - | Y | Y (`::`) | Y (`.`) | - |
| Receiver/method extraction | - | - | Y | Y (`impl`) | Y | - |
| Struct/interface extraction | Y (interface/type members) | - | Y | Y | Y | - |
| Macro call detection | - | - | - | Y (`name!`) | - | - |
| Arrow function classification | Y | - | - | - | - | - |
| Barrel file resolution | Y | - | - | - | - | - |
| Visibility (uppercase convention) | - | - | Y | - | - | - |
| Visibility (`_private` convention) | - | Y | - | - | - | - |
| Visibility (`pub` modifier) | - | - | - | Y | - | - |
| Visibility (`public`/`private`/`protected` modifier) | - | - | - | - | Y | - |

## The NIF

The NIF ships pre-built in the Docker image. Local development needs the Rust toolchain to compile it; see `CLAUDE.md` for the build steps. Without it, only Elixir files are indexed.

When a parser or NIF change lands, an existing index keeps the old extraction until you run `purge` and then `reindex`. Incremental reindex hydrates unchanged files from Qdrant instead of re-parsing them.
