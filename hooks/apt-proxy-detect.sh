#!/bin/bash
# apt ProxyAutoDetect script — auto-discovers proxy via mDNS/DNS,
# falls back to DIRECT if unreachable. Override with config file.

TIMEOUT=2
CONF="/etc/immutable-apt-proxy.conf"

# Common mDNS/DNS names that apt-cacher-ng and similar proxies register
CANDIDATES=(
    "apt-cacher-ng.local"
    "apt-proxy.local"
    "proxy.local"
)

try_proxy() {
    local url="$1"
    local hostport="${url#http://}"
    hostport="${hostport#https://}"
    if timeout "$TIMEOUT" bash -c "echo > /dev/tcp/${hostport%:*}/${hostport#*:}" 2>/dev/null; then
        echo "$url"
        exit 0
    fi
}

# 1. Config file override
if [ -f "$CONF" ]; then
    PROXY=$(grep -oP '^APT_PROXY=\K.*' "$CONF" 2>/dev/null || true)
    [ -n "$PROXY" ] && try_proxy "$PROXY"
fi

# 2. Auto-discover via mDNS/DNS — resolve each candidate and test
for name in "${CANDIDATES[@]}"; do
    ips=$(getent hosts "$name" 2>/dev/null | awk '{print $1}' | sort -u)
    [ -z "$ips" ] && continue
    while IFS= read -r ip; do
        [ -z "$ip" ] && continue
        try_proxy "http://$ip:3142"
    done <<< "$ips"
done

# 3. Nothing reachable
echo "DIRECT"
