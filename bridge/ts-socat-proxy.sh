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
# Khi container THIEU `socat` (cai apt qua proxy hay treo) -> duong 2 chay bang
# `ts-connect-proxy.py` (python3 co san) thay cho socat.
#
# Luu y: script nay chay theo ProxyCommand cua ssh -> stdout CHI duoc phai la
# du lieu mang. Moi dong log/loi phai ra stderr.
# ==============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
# Dung python3 (co san trong container) thay cho bash /dev/tcp: bash build co
# the TAT /dev/tcp (vd Ubuntu bash 5.3) -> duong cu luon roi vao proxy.
# Chi vao duong nay khi probe TCP thanh cong (khong doi banner: dich co the la
# bat ky TCP nao, vd echo server trong test) -> sau do pump stdin/stdout.
PY_HELPER="${TS_CONNECT_PROXY:-$SCRIPT_DIR/ts-connect-proxy.py}"
if command -v python3 >/dev/null 2>&1 \
   && timeout 8 python3 -c 'import socket,sys; socket.create_connection((sys.argv[1],int(sys.argv[2])),6).close()' "$TARGET_HOST" "$TARGET_PORT" 2>/dev/null; then
  # Pump phai chay tu FILE (khong phai heredoc stdin): python doc script tu
  # stdin se an mat du lieu ssh can bom qua socket.
  PUMP="$(mktemp /tmp/ts-pump.XXXXXX.py)" || exit 1
  cat > "$PUMP" <<'PY'
import os, select, socket, sys
sock = socket.create_connection((sys.argv[1], int(sys.argv[2])), 8)
stdin_open = True
while True:
    watch = [sock, 0] if stdin_open else [sock]
    ready, _, _ = select.select(watch, [], [], 60)
    if not ready:
        break
    for src in ready:
        if src is sock:
            data = sock.recv(65536)
            if not data:
                sys.exit(0)
            os.write(1, data)
        else:
            data = os.read(0, 65536)
            if not data:
                stdin_open = False
                try:
                    sock.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
                continue
            sock.sendall(data)
PY
  python3 "$PUMP" "$TARGET_HOST" "$TARGET_PORT"
  rc=$?
  rm -f "$PUMP"
  exit "$rc"
fi

# --- 2) duong cuu: qua HTTP CONNECT proxy cua Hatch ---------------------------
if command -v socat >/dev/null 2>&1; then
  exec socat - "PROXY:$PROXY_HOST:$TARGET_HOST:$TARGET_PORT,proxyport=$PROXY_PORT${AUTH:+,proxyauth=$AUTH}"
fi

# socat khong co -> dung helper python (cung dung proxy CONNECT, khong can goi cai)
if [ -f "$PY_HELPER" ] && command -v python3 >/dev/null 2>&1; then
  exec python3 "$PY_HELPER" "$TARGET_HOST" "$TARGET_PORT"
fi

echo "ts-socat-proxy: khong co socat va khong tim thay $PY_HELPER" >&2
exit 1
