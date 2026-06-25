#!/usr/bin/env bash
# Bereidt WSL-workdir voor en start de headless VPN-container.
# Run vanuit WSL (Ubuntu-20.04). Aanroepen via run.ps1 of handmatig.
set -eu

SRC="/mnt/c/work/git/github/cveld/Experiments/2026-06 wsl container azure vpn"
WORK="$HOME/vpnwork"
NAME="${1:-azurevpntunnel}"
RUNNER="${2:-runner.sh}"
CACHE_SRC="${3:-}"
PROFILE_SRC="${4:-}"

# ── .env laden uit de projectroot ────────────────────────────────────────────
win_to_wsl() {
    local p="$1"
    if [[ "$p" =~ ^[A-Za-z]:\\ ]]; then
        local drive; drive=$(echo "${p:0:1}" | tr '[:upper:]' '[:lower:]')
        echo "/mnt/$drive/${p:3}" | tr '\\' '/'
    else
        echo "$p"
    fi
}

ENV_FILE="$SRC/.env"
if [[ -f "$ENV_FILE" ]]; then
    while IFS='=' read -r key val; do
        key="${key%%#*}"
        key="${key//[[:space:]]/}"
        val="${val%$'\r'}"
        [[ -z "$key" ]] && continue
        printf -v "$key" '%s' "$val"
    done < "$ENV_FILE"
fi

# SECRETS_DIR uit .env gebruiken als fallback (Windows-pad → WSL-pad)
if [[ -n "${SECRETS_DIR:-}" ]]; then
    SECRETS="${SECRETS:-$(win_to_wsl "$SECRETS_DIR")}"
fi

if [[ -z "${SECRETS:-}" ]]; then
    echo "ERROR: SECRETS_DIR not set in .env and SECRETS not set. Copy .env.example to .env and fill in SECRETS_DIR." >&2
    exit 1
fi
# ─────────────────────────────────────────────────────────────────────────────

mkdir -p "$WORK"
cp "$SRC/src/dr.pem"                     "$WORK/dr.pem"
if [[ -n "$CACHE_SRC" ]]; then
    cp "$CACHE_SRC" "$WORK/msalcache.json"
else
    cp "$SECRETS/token-cache/msalcache.json" "$WORK/msalcache.json"
fi
if [[ -n "$PROFILE_SRC" ]]; then
    cp "$PROFILE_SRC" "$WORK/profile.xml"
else
    cp "$SECRETS/vpn/azurevpnconfig.xml" "$WORK/profile.xml"
fi
cp "$SRC/src/"*.sh                       "$WORK/" 2>/dev/null || true

echo "work dir: $WORK"

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" \
  --cap-add=NET_ADMIN --cap-add=NET_RAW --cap-add=SYS_PTRACE \
  --device=/dev/net/tun \
  --sysctl net.ipv4.ip_forward=1 \
  -v "$WORK:/work" \
  --entrypoint sh azurevpn-shim:local "/work/$RUNNER"
echo "started container: $NAME"
