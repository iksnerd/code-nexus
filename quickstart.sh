#!/bin/bash

set -e

echo "🚀 ElixirNexus Quick Start"
echo "=========================="
echo ""

# Check if Qdrant is running
echo "1️⃣  Checking Qdrant..."
if ! curl -s http://localhost:6334/health > /dev/null 2>&1; then
    echo "❌ Qdrant not running. Starting it..."
    docker-compose up qdrant -d
    echo "⏳ Waiting for Qdrant to be healthy..."
    sleep 5
    echo "✅ Qdrant started"
else
    echo "✅ Qdrant is running"
fi

echo ""
echo "2️⃣  Installing Elixir dependencies..."
mix deps.get
echo "✅ Dependencies installed"

echo ""
echo "3️⃣  Compiling application..."
mix compile
echo "✅ Application compiled"

echo ""
echo "4️⃣  Starting ElixirNexus server..."
echo "   Dashboard: http://localhost:4000"
echo "   Search: http://localhost:4000/search"
echo "   API: http://localhost:4000/api"
echo ""
echo "   To index code, open another terminal and run:"
echo "   mix index lib/"
echo ""

mix run --no-halt
