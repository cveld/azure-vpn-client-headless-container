#!/bin/bash
# Desired configuration is persistent; process state is container-local.
set -eu
config=/work/vpn-services
state=/run/vpn-services
mkdir -p "$config" "$state"

alive() {
    local service=$1 pid expected
    expected=socat
    [ "$service" != proxy ] || expected=tinyproxy
    [ -s "$state/$service.pids" ] || return 1
    while read -r pid; do
        [ -r "/proc/$pid/comm" ] || return 1
        [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = "$expected" ] || return 1
        kill -0 "$pid" 2>/dev/null || return 1
        [ "$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)" != Z ] || return 1
    done < "$state/$service.pids"
}

stop() {
    local service=$1 pid expected
    expected=socat
    [ "$service" != proxy ] || expected=tinyproxy
    if [ -f "$state/$service.pids" ]; then
        while read -r pid; do
            if [ -r "/proc/$pid/comm" ] && [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = "$expected" ]; then
                kill "$pid" 2>/dev/null || true
                for ((i=0; i<50; i++)); do
                    [ -r "/proc/$pid/stat" ] || break
                    [ "$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)" != Z ] || break
                    sleep .1
                done
            fi
        done < "$state/$service.pids"
    fi
    rm -f "$state/$service.pids" "$state/$service.hash"
}

reconcile() {
    local service=$1 file hash local_port host port
    file="$config/$service.conf"
    if [ ! -s "$file" ]; then stop "$service"; return; fi
    hash=$(sha256sum "$file" | cut -d' ' -f1)
    if [ "$hash" = "$(cat "$state/$service.hash" 2>/dev/null || true)" ] && alive "$service"; then return; fi
    stop "$service"
    if [ "$service" = proxy ]; then
        tinyproxy -d -c "$file" >> "$state/proxy.log" 2>&1 9>&- &
        echo "$!" > "$state/proxy.pids"
    else
        while read -r local_port host port; do
            [[ "$local_port" =~ ^[0-9]+$ && "$host" =~ ^[a-zA-Z0-9.-]+$ && "$port" =~ ^[0-9]+$ ]] ||
                { echo "Invalid forwarding configuration" >&2; stop forward; return 1; }
            socat "TCP-LISTEN:$local_port,fork,reuseaddr,bind=0.0.0.0" "TCP:$host:$port" >> "$state/forward.log" 2>&1 9>&- &
            echo "$!" >> "$state/forward.pids"
        done < "$file"
    fi
    sleep .2
    alive "$service" || { cat "$state/$service.log" >&2; return 1; }
    printf '%s\n' "$hash" > "$state/$service.hash"
}

action=${1:-status}
service=${2:-}
case "$action" in
    watch)
        while true; do
            "$0" reconcile forward || true
            "$0" reconcile proxy || true
            sleep 2 &
            wait $!
        done
        ;;
    status|reconcile|disable)
        [[ "$service" = proxy || "$service" = forward ]] || exit 2
        exec 9>"$state/lock"
        flock 9
        case "$action" in
            status) [ -s "$config/$service.conf" ] && alive "$service" ;;
            reconcile) reconcile "$service" ;;
            disable) rm -f "$config/$service.conf"; stop "$service" ;;
        esac
        ;;
    *) exit 2 ;;
esac
