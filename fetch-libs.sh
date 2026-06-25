#!/usr/bin/env bash
# fetch-libs.sh — fetch Microsoft Azure VPN Client libs and place them in src/libs/
#
# Usage:
#   bash fetch-libs.sh                            # apt download (version from .env or DEB_VERSION)
#   bash fetch-libs.sh --libs-dir DIR             # copy .so files from existing directory (skip apt)
#   bash fetch-libs.sh --local FILE.deb           # use local .deb file (skip apt)
#   bash fetch-libs.sh --force                    # re-fetch even if already present
#   DEB_VERSION=3.1.0 bash fetch-libs.sh          # override version via env var
#
# Configuration via .env in the project root:
#   LIBS_SOURCE=C:\path\to\existing\libs          → same as --libs-dir (Windows path OK)
#   DEB_VERSION=3.0.0                             → version for apt download
#
# Result: src/libs/ containing libLinuxCore.so, libXplatSharedLibrary.so, libmat.so

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Load .env (Windows paths are automatically recognised) ───────────────────
win_to_wsl() {
    local p="$1"
    # Detect Windows path: starts with drive letter + :\
    if [[ "$p" =~ ^[A-Za-z]:\\ ]]; then
        local drive; drive=$(echo "${p:0:1}" | tr '[:upper:]' '[:lower:]')
        echo "/mnt/$drive/${p:3}" | tr '\\' '/'
    else
        echo "$p"
    fi
}

if [[ -f "$SCRIPT_DIR/.env" ]]; then
    while IFS='=' read -r key val; do
        key="${key%%#*}"          # strip inline comment
        key="${key//[[:space:]]/}"  # trim whitespace
        val="${val%$'\r'}"        # trim Windows CRLF
        [[ -z "$key" ]] && continue
        printf -v "$key" '%s' "$val"
    done < "$SCRIPT_DIR/.env"
fi

# ── Version configuration ────────────────────────────────────────────────────
DEB_VERSION="${DEB_VERSION:-3.0.0}"
# ─────────────────────────────────────────────────────────────────────────────

REQUIRED_LIBS=(
    libLinuxCore.so
    libXplatSharedLibrary.so
    libmat.so
)

EXTRACT_DIR="$SCRIPT_DIR/src/extract"
LIBS_DIR="$SCRIPT_DIR/src/libs"
SRC_LIBDIR="$EXTRACT_DIR/opt/microsoft/microsoft-azurevpnclient/lib"
FORCE=0
LOCAL_DEB=""
LIBS_SOURCE_ARG=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)     FORCE=1; shift ;;
        --local)     LOCAL_DEB="$2"; shift 2 ;;
        --libs-dir)  LIBS_SOURCE_ARG="$2"; shift 2 ;;
        *)           echo "Unknown argument: $1"; echo "Usage: --libs-dir DIR | --local FILE | --force"; exit 1 ;;
    esac
done

# --libs-dir argument takes priority; then LIBS_SOURCE from .env
LIBS_SOURCE_FINAL=""
if [[ -n "$LIBS_SOURCE_ARG" ]]; then
    LIBS_SOURCE_FINAL="$(win_to_wsl "$LIBS_SOURCE_ARG")"
elif [[ -n "${LIBS_SOURCE:-}" ]]; then
    LIBS_SOURCE_FINAL="$(win_to_wsl "$LIBS_SOURCE")"
fi

# ── Idempotency check ────────────────────────────────────────────────────────
if [[ -f "$LIBS_DIR/libLinuxCore.so" ]] && [[ $FORCE -eq 0 ]]; then
    echo "✓ Libraries already present in src/libs/ — nothing to do."
    echo "  Use --force to re-fetch."
    exit 0
fi

# ── Mode A: copy from existing directory ─────────────────────────────────────
if [[ -n "$LIBS_SOURCE_FINAL" ]]; then
    echo "Copying from: $LIBS_SOURCE_FINAL"
    if [[ ! -d "$LIBS_SOURCE_FINAL" ]]; then
        echo "Error: directory not found: $LIBS_SOURCE_FINAL"
        exit 1
    fi
    rm -rf "$LIBS_DIR"
    mkdir -p "$LIBS_DIR"
    MISSING=0
    for lib in "${REQUIRED_LIBS[@]}"; do
        if [[ -f "$LIBS_SOURCE_FINAL/$lib" ]]; then
            cp "$LIBS_SOURCE_FINAL/$lib" "$LIBS_DIR/$lib"
            echo "  ✓ $lib ($(du -h "$LIBS_DIR/$lib" | cut -f1))"
        else
            echo "  ✗ MISSING: $LIBS_SOURCE_FINAL/$lib"
            MISSING=1
        fi
    done
    [[ $MISSING -eq 1 ]] && { echo "Error: not all libs found."; exit 1; }
    echo ""
    echo "✓ Libraries ready in src/libs/ (from $LIBS_SOURCE_FINAL)"
    exit 0
fi

# ── Mode B: local .deb or apt download ───────────────────────────────────────
WORK_DIR="$(mktemp -d)"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

if [[ -n "$LOCAL_DEB" ]]; then
    [[ ! -f "$LOCAL_DEB" ]] && { echo "Error: local .deb not found: $LOCAL_DEB"; exit 1; }
    DEB_FILE="$LOCAL_DEB"
    echo "Using local .deb: $(basename "$DEB_FILE")"
else
    if ! apt-cache show microsoft-azurevpnclient >/dev/null 2>&1; then
        echo "Adding Microsoft apt repo..."
        curl -sSl https://packages.microsoft.com/keys/microsoft.asc \
            | sudo tee /etc/apt/trusted.gpg.d/microsoft.asc >/dev/null
        UBUNTU_VER="$(lsb_release -rs 2>/dev/null || echo "22.04")"
        curl -s "https://packages.microsoft.com/config/ubuntu/${UBUNTU_VER}/prod.list" \
            | sudo tee /etc/apt/sources.list.d/microsoft-ubuntu-prod.list >/dev/null
        sudo apt-get update -q
    fi
    if [[ -n "$DEB_VERSION" ]]; then
        echo "Downloading: microsoft-azurevpnclient=$DEB_VERSION..."
        ( cd "$WORK_DIR" && sudo apt-get download "microsoft-azurevpnclient=$DEB_VERSION" )
    else
        echo "Downloading: microsoft-azurevpnclient (latest)..."
        ( cd "$WORK_DIR" && sudo apt-get download microsoft-azurevpnclient )
    fi
    DEB_FILE="$(ls "$WORK_DIR"/microsoft-azurevpnclient_*.deb | head -1)"
    echo "Downloaded: $(basename "$DEB_FILE")"
fi

echo "Extracting to $EXTRACT_DIR..."
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
dpkg-deb --extract "$DEB_FILE" "$EXTRACT_DIR"
dpkg-deb --control "$DEB_FILE" "$EXTRACT_DIR/DEBIAN"

echo "Copying to $LIBS_DIR..."
rm -rf "$LIBS_DIR"
mkdir -p "$LIBS_DIR"
MISSING=0
for lib in "${REQUIRED_LIBS[@]}"; do
    if [[ -f "$SRC_LIBDIR/$lib" ]]; then
        cp "$SRC_LIBDIR/$lib" "$LIBS_DIR/$lib"
    else
        echo "  ✗ MISSING in package: $lib"
        MISSING=1
    fi
done
[[ $MISSING -eq 1 ]] && { echo "Error: not all libs present in package."; exit 1; }

echo ""
echo "Verifying src/libs/:"
for lib in "${REQUIRED_LIBS[@]}"; do
    echo "  ✓ $lib ($(du -h "$LIBS_DIR/$lib" | cut -f1))"
done

EXTRACTED_VER="$(grep -oP '(?<=Version: ).*' "$EXTRACT_DIR/DEBIAN/control" 2>/dev/null || echo "unknown")"
echo ""
echo "✓ Libraries ready (version: $EXTRACTED_VER)"
echo ""
echo "Next step: docker build -f src/Containerfile -t azurevpn-shim:local src"
