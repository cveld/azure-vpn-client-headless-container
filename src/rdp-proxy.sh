#!/usr/bin/env bash
# WSL2 helper for rdp-vpn.ps1
# Usage: rdp-proxy.sh start <container> <hostname> [local-port] [remote-port]
#        rdp-proxy.sh stop  <hostname>
set -e

ACTION=$1

case "$ACTION" in
  start)
    CONTAINER=$2
    HOSTNAME=$3
    LOCAL_PORT=${4:-13389}
    REMOTE_PORT=${5:-3389}
    # Include VPN container name so two profiles connecting to the same device name never collide.
    SAFE="$(printf '%s-%s' "${CONTAINER}" "${HOSTNAME%%.*}" | tr -dc 'a-zA-Z0-9-' | cut -c1-60)"
    BRIDGE="rdp-bridge-${SAFE}"
    EXPOSE="rdp-expose-${SAFE}"

    # Pull alpine/socat once (silent)
    docker image inspect alpine/socat >/dev/null 2>&1 \
      || docker pull alpine/socat >/dev/null 2>&1

    # Remove any stale containers from a previous run
    docker rm -f "$BRIDGE" "$EXPOSE" >/dev/null 2>&1 || true

    # Bridge container: shares VPN network namespace → can reach internal hosts via VPN routes + DNS
    docker run -d --rm \
      --name "$BRIDGE" \
      --network "container:${CONTAINER}" \
      alpine/socat \
      "TCP-LISTEN:${LOCAL_PORT},fork,reuseaddr" \
      "TCP:${HOSTNAME}:${REMOTE_PORT}" >/dev/null

    # Get VPN container's IP on the Docker bridge (reachable from any container on the same bridge)
    VPN_IP=$(docker inspect -f \
      '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
      "${CONTAINER}")

    # Expose container: publishes the port to WSL2 → Windows auto-forwards via localhost
    docker run -d --rm \
      --name "$EXPOSE" \
      -p "${LOCAL_PORT}:${LOCAL_PORT}" \
      alpine/socat \
      "TCP-LISTEN:${LOCAL_PORT},fork,reuseaddr" \
      "TCP:${VPN_IP}:${LOCAL_PORT}" >/dev/null

    echo "ok"
    ;;

  stop)
    # Accept both old form (hostname only) and new form (container hostname).
    if [ -n "$3" ]; then
      CONTAINER=$2
      HOSTNAME=$3
    else
      CONTAINER=""
      HOSTNAME=$2
    fi
    if [ -n "$CONTAINER" ]; then
      SAFE="$(printf '%s-%s' "${CONTAINER}" "${HOSTNAME%%.*}" | tr -dc 'a-zA-Z0-9-' | cut -c1-60)"
    else
      SAFE="${HOSTNAME%%.*}"
    fi
    docker stop "rdp-bridge-${SAFE}" "rdp-expose-${SAFE}" >/dev/null 2>&1 || true
    ;;

  *)
    echo "Usage: $0 start|stop <container> <hostname> [local-port] [remote-port]" >&2
    exit 1
    ;;
esac
