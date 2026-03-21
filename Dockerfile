FROM elixir:1.19.5-otp-27-slim

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
COPY test test

# Compile application
RUN mix compile

# Copy entrypoint script
COPY docker-entrypoint.sh ./
RUN chmod +x docker-entrypoint.sh

# Expose ports (Phoenix + MCP HTTP)
EXPOSE 4000 3001

# Start both Phoenix and MCP HTTP servers
CMD ["./docker-entrypoint.sh"]
