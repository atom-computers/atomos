#!/bin/bash
# Seed the SurrealDB tool registry with pre-computed embeddings.
#
# Must run AFTER install-surrealdb.sh, install-atomos-agents.sh, and
# install-ollama-applet.sh so that SurrealDB schemas, the Python
# agents package (deepagents + custom tools), Ollama, and the
# nomic-embed-text model are all available.
set -euo pipefail

echo "Seeding tool registry into SurrealDB..."

# Start SurrealDB in the background
/usr/local/bin/surreal start --user root --pass root surrealkv:///var/lib/surrealdb/data.db &
SURREAL_PID=$!

# Start Ollama in the background
export OLLAMA_MODELS="/usr/share/ollama/.ollama/models"
ollama serve &
OLLAMA_PID=$!

# Wait for both services
echo "Waiting for SurrealDB..."
timeout 30 bash -c 'until curl -s http://localhost:8000/health > /dev/null; do sleep 1; done'

echo "Waiting for Ollama..."
timeout 30 bash -c 'until curl -s http://localhost:11434 > /dev/null; do sleep 1; done'

# Run the registry seeder
cd /opt/atomos/agents/src
PYTHONPATH=/opt/atomos/agents/src python3 -c "
import logging, sys
logging.basicConfig(level=logging.INFO)
from tool_registry import populate_registry

count = populate_registry()
if count == 0:
    print('ERROR: No tools were seeded into the registry', file=sys.stderr)
    sys.exit(1)
print(f'Successfully seeded {count} tools into the registry')
"

# Shut down background services
kill $OLLAMA_PID
wait $OLLAMA_PID || true

kill $SURREAL_PID
wait $SURREAL_PID || true

echo "Tool registry seeded successfully"
