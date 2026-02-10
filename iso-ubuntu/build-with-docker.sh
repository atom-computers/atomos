#!/bin/bash
# Build the ISO using Docker container
# Builds inside container filesystem to avoid macOS volume mount permission issues
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== AtomOS Ubuntu ISO Builder (Docker) ===${NC}"

# Check if docker is installed
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: docker is not installed${NC}"
    echo "Install from: https://www.docker.com/products/docker-desktop"
    exit 1
fi

# Check if docker daemon is running
if ! docker info &> /dev/null; then
    echo -e "${RED}Error: Docker daemon is not running${NC}"
    echo "Please start Docker Desktop"
    exit 1
fi

# Build the container image
IMAGE_NAME="atomos-iso-builder"
echo -e "${BLUE}Building container image...${NC}"
docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"

# Create container with proper device access
echo -e "${BLUE}Creating build container...${NC}"
CONTAINER_ID=$(docker run -d --privileged --device /dev/null --device /dev/zero --device /dev/random --device /dev/urandom "$IMAGE_NAME" sleep infinity)
trap "docker rm -f $CONTAINER_ID 2>/dev/null || true" EXIT

echo -e "${BLUE}Creating workspace directory in container...${NC}"
docker exec --user root "$CONTAINER_ID" mkdir -p /workspace/iso-ubuntu

echo -e "${BLUE}Copying source files into container...${NC}"
# Use tar to exclude build artifacts and heavy directories
# Use tar to exclude build artifacts and heavy directories
# Use --no-same-owner to prevent permission issues when extracting in container
# Use --warning=no-unknown-keyword to suppress macOS extended attribute warnings
tar --exclude='build' --exclude='.git' --exclude='*.iso' -C "$SCRIPT_DIR" -cf - . | docker exec -i --user root "$CONTAINER_ID" tar -xf - --no-same-owner --warning=no-unknown-keyword -C /workspace/iso-ubuntu/

if [ -d "$PROJECT_ROOT/sync" ]; then
    echo "Copying sync and excluding target/node_modules..."
    docker exec --user root "$CONTAINER_ID" mkdir -p /workspace/sync
    tar --exclude='target' --exclude='node_modules' --exclude='.git' --exclude='__pycache__' -C "$PROJECT_ROOT" -cf - sync | docker exec -i --user root "$CONTAINER_ID" tar -xf - --no-same-owner --warning=no-unknown-keyword -C /workspace/
fi

if [ -d "$PROJECT_ROOT/cosmic-ext-applet-ollama" ]; then
    echo "Copying cosmic-ext-applet-ollama and excluding target..."
    docker exec --user root "$CONTAINER_ID" mkdir -p /workspace/cosmic-ext-applet-ollama
    tar --exclude='target' --exclude='node_modules' --exclude='.git' -C "$PROJECT_ROOT" -cf - cosmic-ext-applet-ollama | docker exec -i --user root "$CONTAINER_ID" tar -xf - --no-same-owner --warning=no-unknown-keyword -C /workspace/
fi

if [ -d "$PROJECT_ROOT/cocoindex" ]; then
    echo "Copying cocoindex and excluding target/uv.lock..."
    docker exec --user root "$CONTAINER_ID" mkdir -p /workspace/cocoindex
    tar --exclude='target' --exclude='node_modules' --exclude='.git' --exclude='uv.lock' -C "$PROJECT_ROOT" -cf - cocoindex | docker exec -i --user root "$CONTAINER_ID" tar -xf - --no-same-owner --warning=no-unknown-keyword -C /workspace/
fi

echo -e "${BLUE}Building ISO inside container...${NC}"
docker exec --user root -w /workspace/iso-ubuntu "$CONTAINER_ID" bash -c "
    set -e
    echo 'Starting ISO build...'
    make iso
    echo 'Build complete!'
    find build -name '*.iso' -type f 2>/dev/null || echo 'No ISO found yet'
"

echo -e "${BLUE}Copying build artifacts back to host...${NC}"
mkdir -p "$SCRIPT_DIR/build"
docker cp "$CONTAINER_ID:/workspace/iso-ubuntu/build/." "$SCRIPT_DIR/build/" 2>/dev/null || {
    echo -e "${RED}Warning: Could not copy build artifacts${NC}"
    docker exec "$CONTAINER_ID" find /workspace/iso-ubuntu/build -type f 2>/dev/null || true
}

docker stop "$CONTAINER_ID"

echo -e "${GREEN}=== Build Complete ===${NC}"
echo -e "ISO location: ${BLUE}$SCRIPT_DIR/build/${NC}"
find "$SCRIPT_DIR/build" -name "*.iso" -type f 2>/dev/null || echo "Checking for ISO..."
