#!/bin/bash
# Build and start the Azure VPN container from WSL2 native
# Requirements: docker or podman installed in WSL2
# Usage: ./run-wsl.sh

set -euo pipefail

IMAGE="azurevpn-shim"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pick docker or podman
if command -v docker &>/dev/null; then
    RUNTIME="docker"
elif command -v podman &>/dev/null; then
    RUNTIME="podman"
else
    echo "No container runtime found. Install docker or podman."
    echo "  Docker:  curl -fsSL https://get.docker.com | sh"
    echo "  Podman:  sudo apt install podman"
    exit 1
fi

echo "Runtime: $RUNTIME"
echo "Building image '$IMAGE'..."
$RUNTIME build -t "$IMAGE" -f "$SCRIPT_DIR/Containerfile" "$SCRIPT_DIR"

echo ""
echo "Starting VPN container..."
echo "You will be shown a URL and a code. Open the URL in your browser and sign in."
echo "(Ctrl+C to stop)"
echo ""

TOKEN_CACHE_DIR="$SCRIPT_DIR/token-cache"
mkdir -p "$TOKEN_CACHE_DIR"

$RUNTIME run --rm -it \
    --cap-add=NET_ADMIN \
    --cap-add=NET_RAW \
    --device=/dev/net/tun \
    --sysctl net.ipv4.ip_forward=1 \
    --name azurevpn-client \
    -v "$TOKEN_CACHE_DIR:/token-cache" \
    "$IMAGE"
