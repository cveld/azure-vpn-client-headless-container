#!/bin/sh
# Hoofdrunner: bereidt omgeving voor en start de shim via de container-entrypoint.
# Draait BINNEN de container als /work/runner.sh (bind-mount vanuit setup_and_run.sh).
cp /work/dr.pem /dr.pem
export VPN_TOKEN="$(cat /work/msalcache.json)"
export PROFILE_XML="$(cat /work/profile.xml)"
# Extract UPN from the token cache (stored as Account[*].username by device_code.py)
AAD_USERNAME=$(python3 -c "
import sys,json,base64
c=json.loads(sys.argv[1])
inner=json.loads(base64.b64decode(next(iter(c.values()))))
acc=next(iter(inner.get('Account',{}).values()),{})
print(acc.get('username',''))
" "$VPN_TOKEN")
export AAD_USERNAME
export CERT_REDIRECT=/dr.pem
export POLL_SECS=3600

# Extraheer profielwaarden uit PROFILE_XML zodat de shim de juiste naam/gateway/tenant gebruikt.
VPN_PROFILE=$(printf '%s' "$PROFILE_XML" | grep -oP '(?<=<name>)[^<]+' | head -1)
VPN_GATEWAY=$(printf '%s' "$PROFILE_XML" | grep -oP '(?<=<fqdn>)[^<]+' | head -1)
VPN_CLIENT=$(printf '%s' "$PROFILE_XML"  | grep -oP '(?<=<audience>)[^<]+' | head -1)
VPN_TENANT=$(printf '%s' "$PROFILE_XML"  | grep -oP '(?<=<tenant>https://login\.microsoftonline\.com/)[^/]+' | head -1)
export VPN_PROFILE VPN_GATEWAY VPN_CLIENT VPN_TENANT

# NB: de library zet de tun-routes zelf via netlink — handmatige `ip route` is NIET nodig.
# DNS-server zet de lib NIET; we zetten die hier zodra de tun up is.
(
  TUN=$(printf '%s' "${VPN_PROFILE}" | tr -d ' ' | cut -c1-15)
  found=0
  for i in $(seq 1 120); do
    if ip link show "$TUN" >/dev/null 2>&1; then
      found=1
      # Haal DNS-server op uit syslog PUSH_REPLY (werkt voor elk profiel)
      DNS=$(grep -oP 'Adding DNS \K[\d.]+' /var/log/syslog 2>/dev/null | tail -1)
      if [ -z "$DNS" ]; then
        echo "[dns] $TUN up na ${i}s; geen DNS in PUSH_REPLY — resolv.conf ongewijzigd"
      else
        echo "[dns] $TUN up na ${i}s; resolv.conf -> $DNS"
        printf 'nameserver %s\n' "$DNS" > /etc/resolv.conf
        cat /etc/resolv.conf
      fi
      break
    fi
    sleep 1
  done
  [ "$found" -eq 0 ] && echo "[dns] TIMEOUT: $TUN verscheen niet binnen 120s"
) &

# LD_PRELOAD pas hier: de DNS-subshell erft het anders en elke ip/grep-aanroep
# triggert de certredirect-constructor → [redir] ACTIEF-spam in de logs.
export LD_PRELOAD=/certredirect.so
exec /entrypoint.sh
