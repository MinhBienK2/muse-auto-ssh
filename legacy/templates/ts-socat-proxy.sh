#!/bin/bash
# ==============================================================================
# ts-socat-proxy.sh - Bridge Tailscale -> HTTP CONNECT proxy (DYNAMIC)
#
# Doc proxy tu HTTPS_PROXY (co the thieu user:pass, port khac nhau giua cac
# container) - fallback quet /proc cua cac process dang chay.
#
# Usage: ts-socat-proxy.sh <target-host> <target-port>
# ==============================================================================
set -u

if [ -z "${HTTPS_PROXY:-}" ] || [[ "${HTTPS_PROXY}" != *"://"* ]]; then
  for p in $(pgrep -u root -f "python|bash|uvicorn|node" 2>/dev/null); do
    hp=$(cat /proc/$p/environ 2>/dev/null | tr "\0" "\n" | grep -m1 "^HTTPS_PROXY=" || true)
    if [ -n "$hp" ] && [[ "$hp" == *"://"* ]]; then
      eval "export $hp"
      break
    fi
  done
fi

url="${HTTPS_PROXY:-http://hatch-egress-proxy:3130}"
rest="${url#*://}"
userpass=""
if [[ "$rest" == *"@"* ]]; then
  userpass="${rest%%@*}"
  rest="${rest#*@}"
fi
proxyhost="${rest%%:*}"
proxyport="${rest##*:}"
[ -z "$proxyhost" ] && proxyhost="hatch-egress-proxy"
[[ "$proxyport" =~ ^[0-9]+$ ]] || proxyport=3130
auth=""
[ -n "$userpass" ] && auth=",proxyauth=${userpass}"

exec socat - "PROXY:${proxyhost}:$1:$2,proxyport=${proxyport}${auth}"
