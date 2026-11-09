#!/bin/sh
# OpenVPN up/down script: apply tunnel DNS and restore bootstrap DNS on disconnect.
# OpenVPN exports each pushed option as $foreign_option_1, _2, ... Lines look
# like "dhcp-option DNS 10.128.0.132".
set -eu
state=/run/vpn-services
mkdir -p "$state"
# The entrypoint captures this snapshot before the first tunnel starts. Also support
# invoking this hook directly in an older container.
if [ ! -f "$state/bootstrap-resolv.conf" ]; then
    cp /etc/resolv.conf "$state/bootstrap-resolv.conf"
fi
if [ "${script_type:-up}" = down ]; then
    cat "$state/bootstrap-resolv.conf" > /etc/resolv.conf
    exit 0
fi
dns=$(mktemp "$state/dns.XXXXXX")
trap 'rm -f "$dns"' EXIT
i=1
while true; do
    eval "opt=\${foreign_option_$i:-}"
    [ -n "$opt" ] || break
    case "$opt" in
        "dhcp-option DNS "*) printf 'nameserver %s\n' "${opt#dhcp-option DNS }" >> "$dns" ;;
    esac
    i=$((i + 1))
done
# Never erase the resolver when a reconnect provides no DNS options.
if [ -s "$dns" ]; then
    cat "$dns" > /etc/resolv.conf
else
    cat "$state/bootstrap-resolv.conf" > /etc/resolv.conf
fi
exit 0
