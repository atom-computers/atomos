#!/bin/bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <config-file> <option-key> <option-value>" >&2
    exit 1
fi

CONFIG_FILE="$1"
OPTION_KEY="$2"
OPTION_VALUE="$3"

python3 - "$CONFIG_FILE" "$OPTION_KEY" "$OPTION_VALUE" <<'PY'
import configparser
import os
import sys

config_file, key, value = sys.argv[1:4]
cfg = configparser.ConfigParser()

if os.path.exists(config_file):
    cfg.read(config_file)

if not cfg.has_section("pmbootstrap"):
    cfg.add_section("pmbootstrap")

cfg.set("pmbootstrap", key, value)

parent = os.path.dirname(config_file)
if parent:
    os.makedirs(parent, exist_ok=True)

with open(config_file, "w", encoding="utf-8") as f:
    cfg.write(f)

print(cfg.get("pmbootstrap", key))
PY
