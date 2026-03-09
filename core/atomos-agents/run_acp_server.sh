#!/bin/bash
# ACP (Agent Client Protocol) server entrypoint for Zed integration.
#
# Zed launches this script as a subprocess and communicates over stdio.
# Configure in Zed's settings.json:
#
#   {
#     "agent_servers": {
#       "AtomOS": {
#         "type": "custom",
#         "command": "/opt/atomos/agents/run_acp_server.sh"
#       }
#     }
#   }
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/src"

export PYTHONPATH="${SRC_DIR}:${PYTHONPATH:-}"
export OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"

exec python3 "${SRC_DIR}/acp_server.py"
