#!/bin/bash
set -eu
mkdir -p /run/vpn-services
# Preserve the original Docker resolver across docker restart, including a hard
# stop that did not run the down hook. A recreated container starts fresh.
if [ ! -s /run/vpn-services/bootstrap-resolv.conf ]; then
    cp /etc/resolv.conf /run/vpn-services/bootstrap-resolv.conf
fi
cat /run/vpn-services/bootstrap-resolv.conf > /etc/resolv.conf
# Runtime PIDs may be reused by unrelated processes after a container restart.
rm -f /run/vpn-services/*.pids /run/vpn-services/*.hash
# Docker ends the watcher and services when OpenVPN exits; tini reaps orphans.
/usr/local/sbin/vpn-services watch &
exec /usr/local/sbin/openvpn "$@"
