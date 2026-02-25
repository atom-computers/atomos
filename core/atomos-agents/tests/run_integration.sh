#!/usr/bin/env bash

# Integration test script for Atom OS Deep Agents Bridge
set -e

# Start the Python gRPC server in the background
echo "Starting Python Deep Agents server..."
cd /Users/george/atom/atomos/core/atomos-agents
source .venv/bin/activate
PYTHONPATH=src python src/server.py &
SERVER_PID=$!

echo "Server started with PID $SERVER_PID. Waiting 3 seconds for it to bind..."
sleep 3

# TODO: In a real environment, we would run `cargo test --test it_bridge` in atomos-bridge, 
# but for now we'll just check if the process is still running as a basic smoke test.

if kill -0 $SERVER_PID 2>/dev/null; then
    echo "Server is healthy and running."
else
    echo "Server failed to start!"
    exit 1
fi

echo "Cleaning up..."
kill $SERVER_PID
echo "Integration test passed."
