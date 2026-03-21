#!/bin/bash
set -e

# Start Phoenix server (port 4100) + MCP HTTP server (port 3001)
# MCP_HTTP_PORT env var tells application.ex to start the MCP HTTP transport
exec mix phx.server
