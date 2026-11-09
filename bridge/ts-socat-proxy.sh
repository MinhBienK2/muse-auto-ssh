#!/bin/bash
# ==============================================================================
# ts-socat-proxy.sh - Bridge container Muse -> may ngoai (noi dung cho ssh)
#
#   ts-socat-proxy.sh <target-host> <target-port>
#
# Hai duong di, thu theo thu tu:
#
#   1) TRUC TIEP: noi thang toi may ngoai. Container co tailscale rieng, nen
#      noi duoc va nhanh (~3s) - NHUNG hien tai container bi chan o tang mang
#      ("Operation not permitted"), nen duong nay thu truoc cho nhanh, that bai
#      thi bao loi ngay (khong ton thoi gian).
#   2) HTTP CONNECT proxy cua Hatch: `hatch-egress-proxy`, port 3130, KHONG can
#      user:pass (port 3128 thi can token, dung sai se ra loi). Day la duong dang
#      chay on dinh trong container.
#
# Luu y: script nay chay theo ProxyCommand cua ssh -> stdout CHI duoc phai la
# du lieu mang. Moi dong log/loi phai ra stderr.
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

# --- 1) duong truc tiep (tailscale cua container) -----------------------------
# Do "keo" (relay) bang /dev/tcp cua bash: stdin -> socket, socket -> stdout.
# Probe 8s de khong treo khi container chua len tailscale.
if timeout 8 bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$TARGET_HOST" "$TARGET_PORT" 2>/dev/null; then
  exec 3<>"/dev/tcp/$TARGET_HOST/$TARGET_PORT" || exit 1
  cat <&3 &
  cat >&3
  wait
  exit 0
fi

# --- 2) duong cuu: qua HTTP CONNECT proxy cua Hatch ---------------------------
exec socat - "PROXY:$PROXY_HOST:$TARGET_HOST:$TARGET_PORT,proxyport=$PROXY_PORT${AUTH:+,proxyauth=$AUTH}"
