#!/bin/bash
# Run inside the VPN image with bash as entrypoint; no VPN credentials needed.
set -eu
service=/usr/local/sbin/vpn-services
mkdir -p /work/vpn-services
printf 'Port 18888\nListen 0.0.0.0\nAllow 127.0.0.1\nLogLevel Warning\n' > /work/vpn-services/proxy.conf
printf '19091 127.0.0.1 19090\n19093 127.0.0.1 19090\n' > /work/vpn-services/forward.conf
socat TCP-LISTEN:19090,fork,reuseaddr EXEC:/bin/cat &
backend=$!
$service watch &
watcher=$!
trap 'kill "$watcher" "$backend" 2>/dev/null || true' EXIT

wait_service() {
    for ((i=0; i<100; i++)); do
        $service status "$1" && return
        sleep .1
    done
    echo "Service did not recover: $1" >&2
    exit 1
}
wait_service forward
wait_service proxy
reply=$(printf 'hello\n' | timeout 3 socat - TCP:127.0.0.1:19091)
[ "$reply" = hello ]
reply=$(printf 'second\n' | timeout 3 socat - TCP:127.0.0.1:19093)
[ "$reply" = second ]
reply=$(printf 'CONNECT 127.0.0.1:19090 HTTP/1.1\r\nHost: 127.0.0.1:19090\r\n\r\n' |
    timeout 2 socat - TCP:127.0.0.1:18888 || true)
[[ "$reply" = *"200 Connection established"* ]]

old=$(cat /run/vpn-services/proxy.pids)
kill "$old"
sleep .3
wait_service proxy
[ "$(cat /run/vpn-services/proxy.pids)" != "$old" ]
# Idempotent reconcile must not churn a healthy process.
current=$(cat /run/vpn-services/proxy.pids)
$service reconcile proxy
[ "$(cat /run/vpn-services/proxy.pids)" = "$current" ]
old=$(head -1 /run/vpn-services/forward.pids)
kill "$old"
sleep .3
wait_service forward
[ "$(head -1 /run/vpn-services/forward.pids)" != "$old" ]
[ "$(wc -l < /run/vpn-services/forward.pids)" = 2 ]
reply=$(printf 'recovered\n' | timeout 3 socat - TCP:127.0.0.1:19093)
[ "$reply" = recovered ]

$service disable forward
! $service status forward
$service status proxy
sleep 3
! $service status forward
[ ! -f /work/vpn-services/forward.conf ]
printf '19092 127.0.0.1 19090\n' > /work/vpn-services/forward.conf
wait_service forward
# Simulate a watcher restart: desired config is retained and restored.
kill "$watcher"
$service disable proxy
printf 'Port 18888\nListen 0.0.0.0\nAllow 127.0.0.1\nLogLevel Warning\n' > /work/vpn-services/proxy.conf
$service watch &
watcher=$!
wait_service proxy
$service disable forward
$service disable proxy
echo "VPN service integration tests passed"
