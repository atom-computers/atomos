#!/bin/bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <profile-env> <pmbootstrap-args...>" >&2
    exit 1
fi

PROFILE_ENV="$1"
shift

if [ ! -f "$PROFILE_ENV" ]; then
    echo "Profile env not found: $PROFILE_ENV" >&2
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$PROFILE_ENV"

PMB_BIN="${PMB_BIN:-pmbootstrap}"
PMB_WORK_EFFECTIVE="${PMB_WORK_OVERRIDE:-$PMB_WORK}"
if [[ "$PMB_WORK_EFFECTIVE" = /* ]]; then
    PMB_WORK_ABS="$PMB_WORK_EFFECTIVE"
else
    PMB_WORK_ABS="$ROOT_DIR/${PMB_WORK_EFFECTIVE}"
fi

# Let pmbootstrap create/manage the work directory lifecycle itself.
# Creating it here can produce an incomplete directory that triggers
# "work folder version needs to be migrated" before init runs.
mkdir -p "$(dirname "$PMB_WORK_ABS")"

exec "$PMB_BIN" -w "$PMB_WORK_ABS" "$@"
