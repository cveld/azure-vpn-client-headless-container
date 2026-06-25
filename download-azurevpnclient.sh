#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$SCRIPT_DIR/downloaded"
mkdir -p "$DEST"

# Install curl if missing
sudo apt-get install -y curl

# Microsoft public key
curl -sSl https://packages.microsoft.com/keys/microsoft.asc | sudo tee /etc/apt/trusted.gpg.d/microsoft.asc

# Detect Ubuntu release and add appropriate repo
UBUNTU_VERSION=$(lsb_release -rs 2>/dev/null || echo "")
case "$UBUNTU_VERSION" in
  20.04)
    curl https://packages.microsoft.com/config/ubuntu/20.04/prod.list | sudo tee /etc/apt/sources.list.d/microsoft-ubuntu-focal-prod.list
    ;;
  22.04)
    curl https://packages.microsoft.com/config/ubuntu/22.04/prod.list | sudo tee /etc/apt/sources.list.d/microsoft-ubuntu-jammy-prod.list
    ;;
  *)
    echo "Unrecognised Ubuntu version '$UBUNTU_VERSION', trying 22.04 repo"
    curl https://packages.microsoft.com/config/ubuntu/22.04/prod.list | sudo tee /etc/apt/sources.list.d/microsoft-ubuntu-jammy-prod.list
    ;;
esac

sudo apt-get update

# Download the .deb (and its dependencies) into $DEST without installing
cd "$DEST"
sudo apt-get download microsoft-azurevpnclient

# apt-get download only fetches the named package; grab direct deps too
DEPS=$(apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts \
        --no-breaks --no-replaces --no-enhances microsoft-azurevpnclient \
    | grep '^\w' | sort -u)
for pkg in $DEPS; do
    sudo apt-get download "$pkg" 2>/dev/null || true
done

echo ""
echo "Downloaded packages:"
ls -lh "$DEST"/*.deb 2>/dev/null || echo "(none found)"
