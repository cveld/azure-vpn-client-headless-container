#!/bin/bash
# Maakt de MSAL-tokencache (msalcache.json) beschikbaar voor de headless shim.
#
# WORKFLOW (zie docs/headless-pipeline.md):
#   STAP 0  - check EERST of een bestaande cache volstaat:
#               python3 src/inspect_cache.py <repo>/token-cache/*.json
#             Heeft msalcache.json een niet-verlopen RefreshToken? Dan klaar; geen keyring nodig.
#   STAP 1  - pas als stap 0 faalt: dit script (keyring unlock via GUI-prompt).
#
# Draai dit in je EIGEN WSL-terminal. Er verschijnt een WSLg GUI-dialoog die om het
# "Default keyring"-wachtwoord vraagt; typ dat in. Het wachtwoord loopt NIET via tooling.
# Output: argv[1] (default: map van dit script).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE}"
export XDG_RUNTIME_DIR=/run/user/1000
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
export DISPLAY=:0
export WAYLAND_DISPLAY=wayland-0

# 1. keyring-daemon draaien (secrets-component). LET OP: kale 'python3' kan linuxbrew zijn
#    ZONDER secretstorage -> gebruik altijd /usr/bin/python3 (heeft python3-secretstorage).
if ! pgrep -f "gnome-keyring-daemon" >/dev/null; then
  echo "gnome-keyring-daemon starten..."
  eval "$(gnome-keyring-daemon --start --components=secrets,pkcs11 2>/dev/null)"
  sleep 1
fi
echo "daemon: $(pgrep -af gnome-keyring-daemon | head -1)"

# 2. unlock (GUI-prompt) + extract -> msalcache.json
/usr/bin/python3 "$HERE/unlock_extract.py" "$OUT"
echo "exit=$?  (gelukt = 'OK: msalcache.json = N bytes')"
