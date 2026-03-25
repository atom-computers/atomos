#!/bin/bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <config-file> <provider-key> <provider-value>" >&2
    exit 1
fi

CONFIG_FILE="$1"
PROVIDER_KEY="$2"
PROVIDER_VALUE="$3"

python3 - "$CONFIG_FILE" "$PROVIDER_KEY" "$PROVIDER_VALUE" <<'PY'
import configparser
import os
import sys

config_file, provider_key, provider_value = sys.argv[1:4]
cfg = configparser.ConfigParser()

if os.path.exists(config_file):
    cfg.read(config_file)

if not cfg.has_section("providers"):
    cfg.add_section("providers")

cfg.set("providers", provider_key, provider_value)

parent = os.path.dirname(config_file)
if parent:
    os.makedirs(parent, exist_ok=True)

with open(config_file, "w", encoding="utf-8") as f:
    cfg.write(f)
PY

echo "Set provider: ${PROVIDER_KEY}=${PROVIDER_VALUE}"
