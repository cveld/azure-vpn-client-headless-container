#!/bin/sh
# OpenVPN --up script: apply pushed DNS server(s) to /etc/resolv.conf.
# OpenVPN exports each pushed option as $foreign_option_1, _2, ... Lines look
# like "dhcp-option DNS 10.128.0.132".
: > /etc/resolv.conf
i=1
while true; do
    eval "opt=\${foreign_option_$i:-}"
    [ -n "$opt" ] || break
    case "$opt" in
        "dhcp-option DNS "*) echo "nameserver ${opt#dhcp-option DNS }" >> /etc/resolv.conf ;;
    esac
    i=$((i + 1))
done
exit 0
