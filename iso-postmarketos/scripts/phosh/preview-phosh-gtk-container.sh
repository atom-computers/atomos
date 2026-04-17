#!/bin/bash
# Quick Phosh-adjacent UI preview helper.
# Default mode runs the egui preview locally. Optional container mode runs the
# same egui preview under Linux + X11 forwarding.
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: preview-phosh-gtk-container.sh [--container-x11] [--image <container-image>]

Modes:
  local (default)       Run egui preview on host
  --container-x11       Run egui preview in Linux container over X11

Environment:
  ATOMOS_PREVIEW_CONTAINER_IMAGE   Container image (default: rust:1-bookworm)
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_CONTAINER=0
CONTAINER_IMAGE="${ATOMOS_PREVIEW_CONTAINER_IMAGE:-rust:1-bookworm}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --container-x11)
            RUN_CONTAINER=1
            ;;
        --image)
            shift
            [ "$#" -gt 0 ] || { echo "ERROR: --image requires a value" >&2; exit 2; }
            CONTAINER_IMAGE="$1"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown option: $1" >&2
            usage
            exit 2
            ;;
    esac
    shift
done

if [ "$RUN_CONTAINER" = "0" ]; then
    exec bash "$ROOT_DIR/scripts/overview-chat-ui/preview-overview-chat-ui-egui.sh"
fi

if [ "$(uname -s)" != "Linux" ]; then
    echo "ERROR: --container-x11 is supported on Linux hosts only." >&2
    echo "Run local egui preview instead:" >&2
    echo "  bash scripts/overview-chat-ui/preview-overview-chat-ui-egui.sh" >&2
    exit 2
fi

if [ -z "${DISPLAY:-}" ]; then
    echo "ERROR: DISPLAY is not set; start an X11 session first." >&2
    exit 2
fi

ENGINE=""
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    ENGINE="docker"
elif command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
    ENGINE="podman"
else
    echo "ERROR: need a working docker or podman daemon for --container-x11." >&2
    exit 2
fi

echo "Launching egui preview in container ($ENGINE, image=$CONTAINER_IMAGE)."
echo "If rendering fails, allow local X clients first: xhost +local:docker"

exec "$ENGINE" run --rm -it \
    -e DISPLAY="$DISPLAY" \
    -v /tmp/.X11-unix:/tmp/.X11-unix \
    -v "$ROOT_DIR":/work/iso-postmarketos \
    -w /work/iso-postmarketos \
    "$CONTAINER_IMAGE" \
    bash -lc '
        set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive
        apt-get update >/dev/null
        apt-get install -y --no-install-recommends \
            pkg-config \
            libasound2-dev \
            libgl1-mesa-dev \
            libwayland-dev \
            libx11-dev \
            libxcursor-dev \
            libxi-dev \
            libxinerama-dev \
            libxkbcommon-dev \
            libxrandr-dev >/dev/null
        bash scripts/overview-chat-ui/preview-overview-chat-ui-egui.sh
    '
