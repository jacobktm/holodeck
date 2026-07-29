#!/bin/bash
# apt ProxyAutoDetect script.
# If a proxy is configured and reachable, use it; otherwise go direct.
# Configure by creating /etc/immutable-apt-proxy.conf with:
#   APT_PROXY=http://hostname:port

CONF="/etc/immutable-apt-proxy.conf"
TIMEOUT=2

[ -f "$CONF" ] || { echo "DIRECT"; exit 0; }

PROXY=$(grep -oP '^APT_PROXY=\K.*' "$CONF" 2>/dev/null || true)
[ -n "$PROXY" ] || { echo "DIRECT"; exit 0; }

# Strip protocol for host:port check
HOSTPORT="${PROXY#http://}"
HOSTPORT="${HOSTPORT#https://}"

if timeout "$TIMEOUT" bash -c "echo > /dev/tcp/${HOSTPORT%:*}/${HOSTPORT#*:}" 2>/dev/null; then
    echo "$PROXY"
else
    echo "DIRECT"
fi
