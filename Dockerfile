# Stage 1: Builder — compiles deps, NIF, and application
FROM elixir:1.19.5-otp-27-slim AS builder

WORKDIR /app

# Install build dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install Rust (for tree-sitter NIF compilation)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

# Copy mix files first for better layer caching
COPY mix.exs mix.lock ./

# Install Elixir dependencies (limit parallelism to avoid OOM)
RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get

# Compile deps separately to limit memory usage
ENV ERL_FLAGS="+JMsingle true"
RUN mix deps.compile --no-optional 2>/dev/null; mix deps.compile || true

# Patch ex_mcp tool call timeout (10s -> 120s) for long-running tools like reindex
RUN sed -i 's/{:execute_tool, tool_name, arguments}, 10000/{:execute_tool, tool_name, arguments}, 120_000/' deps/ex_mcp/lib/ex_mcp/message_processor.ex && \
    mix deps.compile ex_mcp --force

# Copy native code (Rust NIFs)
COPY native native

# Copy source code and config
COPY lib lib
COPY config config
COPY priv priv

# Remove macOS NIF binary (will be rebuilt for Linux below)
RUN rm -f priv/native/tree_sitter_nif.so

# Compile application + rebuild tree-sitter NIF for Linux
# Temporarily enable NIF compilation by patching skip_compilation
RUN sed -i 's/skip_compilation?: true/skip_compilation?: false/' lib/elixir_nexus/tree_sitter_parser.ex && \
    mix compile --force && \
    sed -i 's/skip_compilation?: false/skip_compilation?: true/' lib/elixir_nexus/tree_sitter_parser.ex

# Stage 2: Runtime — slim image without Rust toolchain or build tools
FROM elixir:1.19.5-otp-27-slim AS runtime

WORKDIR /app

# Only runtime dependencies — inotify-tools for file watching
RUN apt-get update && apt-get install -y \
    inotify-tools \
    && rm -rf /var/lib/apt/lists/*

# Copy hex/rebar from builder so mix commands work at runtime
COPY --from=builder /root/.mix /root/.mix
COPY --from=builder /root/.hex /root/.hex

# Copy compiled application from builder
COPY --from=builder /app/mix.exs /app/mix.lock ./
COPY --from=builder /app/deps deps
COPY --from=builder /app/_build _build
COPY --from=builder /app/lib lib
COPY --from=builder /app/config config
COPY --from=builder /app/priv priv

# Copy entrypoint script
COPY docker-entrypoint.sh ./
RUN chmod +x docker-entrypoint.sh

# Expose ports (Phoenix + MCP HTTP)
EXPOSE 4100 3001

# Start both Phoenix and MCP HTTP servers
CMD ["./docker-entrypoint.sh"]
