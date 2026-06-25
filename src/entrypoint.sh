#!/bin/sh
# Start syslogd (busybox) + run shim, capture all syslog output.
# Syslogd is VERPLICHT: zonder syslogd crasht Go's logrus (nil Logger in CacheAccessor).
busybox syslogd -n -O /var/log/syslog &
SYSLOGD_PID=$!
sleep 0.2
/vpnshim &
SHIM_PID=$!
wait $SHIM_PID
kill $SYSLOGD_PID 2>/dev/null || true
echo "=== syslog output ==="
cat /var/log/syslog 2>/dev/null || echo "(geen syslog berichten)"
