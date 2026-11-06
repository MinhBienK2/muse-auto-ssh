#!/bin/bash
# ==============================================================================
# ts-socat-proxy.sh - Bridge Tailscale -> HTTP CONNECT proxy (Hatch egress)
#
#   ts-socat-proxy.sh <target-host> <target-port>
#
# Proxy cua container Muse: host `hatch-egress-proxy`, port `3130`, KHONG can
# user:pass (da kiem chung bang CONNECT thu tren container that).
#
# Luu y: `/etc/environment` trong container chi tro `hatch-egress-proxy:3128` -
# port 3128 YEU credential (token trong /proc/<pid>/environ cua tieng trinh
# Hatch). Port 3130 thi mo khong can auth, nen dung port 3130.
# ==============================================================================
set -u

TARGET_HOST="${1:?target host}"
TARGET_PORT="${2:?target port}"

PROXY_HOST="${PROXY_HOST:-hatch-egress-proxy}"
PROXY_PORT="${PROXY_PORT:-3130}"

# Neu proxy yeu auth (bien HTTPS_PROXY co user:pass) thi lay tu env.
AUTH=""
U="${HTTPS_PROXY:-}"
if [ -n "$U" ]; then
  U="${U#*://}"
  case "$U" in
    *@*) AUTH="${U%%@*}";;
  esac
fi

exec socat - "PROXY:$PROXY_HOST:$TARGET_HOST:$TARGET_PORT,proxyport=$PROXY_PORT${AUTH:+,proxyauth=$AUTH}"
