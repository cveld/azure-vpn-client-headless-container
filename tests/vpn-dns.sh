#!/bin/bash
# Run in an isolated container: never change the active VPN's resolver.
set -eu
hook=/source/src-openvpn/up-dns.sh
mkdir -p /run/vpn-services
cp /etc/resolv.conf /run/vpn-services/bootstrap-resolv.conf
bootstrap=$(cat /etc/resolv.conf)
trap 'cat /run/vpn-services/bootstrap-resolv.conf > /etc/resolv.conf' EXIT

env script_type=up foreign_option_1='dhcp-option DNS 10.0.0.4' \
    foreign_option_2='dhcp-option DNS 10.0.0.5' sh "$hook"
[ "$(cat /etc/resolv.conf)" = $'nameserver 10.0.0.4\nnameserver 10.0.0.5' ]

# Soft disconnect must restore a resolver that can reach the public gateway.
env script_type=down sh "$hook"
[ "$(cat /etc/resolv.conf)" = "$bootstrap" ]
env script_type=up foreign_option_1='dhcp-option DNS 10.1.0.4' sh "$hook"
[ "$(cat /etc/resolv.conf)" = 'nameserver 10.1.0.4' ]

# A profile with no pushed DNS must not leave an empty resolv.conf.
env script_type=up foreign_option_1='dhcp-option DOMAIN example.test' sh "$hook"
[ "$(cat /etc/resolv.conf)" = "$bootstrap" ]
grep -qx up-restart /source/src-openvpn/openvpn.ovpn.template
grep -qx 'down /work/up-dns.sh' /source/src-openvpn/openvpn.ovpn.template
echo "VPN DNS reconnect tests passed"
