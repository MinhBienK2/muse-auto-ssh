#!/bin/bash
# ==============================================================================
# ts-socat-proxy.sh - Bridge Tailscale -> HTTP CONNECT proxy (Hatch egress)
#
# Cac container dung proxy khac nhau (port 3128/3130, co hoac khong co
# user:pass). Script nay THU cac candidate bang mot probe HTTP CONNECT thật
# rồi mới chọn, thay vì đoán.
#
# Usage: ts-socat-proxy.sh <target-host> <target-port>
# ==============================================================================
set -u

TARGET_HOST="${1:?target host}"
TARGET_PORT="${2:?target port}"

# --- lay HTTPS_PROXY (ke ca user:pass) ---------------------------------------
if [ -z "${HTTPS_PROXY:-}" ] || [[ "${HTTPS_PROXY}" != *"://"* ]]; then
  for p in $(pgrep -u root -f "python|bash|uvicorn|node" 2>/dev/null); do
    hp=$(cat /proc/$p/environ 2>/dev/null | tr "\0" "\n" | grep -m1 "^HTTPS_PROXY=" || true)
    if [ -n "$hp" ] && [[ "$hp" == *"://"* ]]; then
      eval "export $hp"
      break
    fi
  done
fi

ENV_URL="${HTTPS_PROXY:-}"
ENV_REST="${ENV_URL#*://}"
ENV_AUTH=""
ENV_HOSTPORT="$ENV_REST"
if [[ "$ENV_REST" == *"@"* ]]; then
  ENV_AUTH="${ENV_REST%%@*}"
  ENV_HOSTPORT="${ENV_REST#*@}"
fi
ENV_PROXY_HOST="${ENV_HOSTPORT%%:*}"
ENV_PROXY_PORT="${ENV_HOSTPORT##*:}"
[[ "$ENV_PROXY_PORT" =~ ^[0-9]+$ ]] || ENV_PROXY_PORT=""
[ -z "$ENV_PROXY_HOST" ] && ENV_PROXY_HOST=""

# --- probe cac candidate, chon cai nao CONNECT duoc --------------------------
pick() {
  python3 - "$1" "$2" "$3" "$4" "$TARGET_HOST" "$TARGET_PORT" <<'PY'
import base64, socket, sys
host, port, auth, label, thost, tport = sys.argv[1:7]
try:
    s = socket.create_connection((host, int(port)), timeout=6)
    req = "CONNECT %s:%s HTTP/1.1\r\nHost: %s:%s\r\n" % (thost, tport, thost, tport)
    if auth:
        req += "Proxy-Authorization: Basic %s\r\n" % base64.b64encode(auth.encode()).decode()
    req += "\r\n"
    s.sendall(req.encode())
    data = s.recv(256)
    s.close()
    ok = data.startswith(b"HTTP/1.1 200") or data.startswith(b"HTTP/1.0 200")
except Exception:
    ok = False
print("%s|%s|%s|%s" % (label, host, port, auth) if ok else "")
PY
}

CHOSEN=""
for cand in \
  "env|$ENV_PROXY_HOST|$ENV_PROXY_PORT|$ENV_AUTH" \
  "p3130|hatch-egress-proxy|3130|$ENV_AUTH" \
  "p3128|hatch-egress-proxy|3128|$ENV_AUTH" \
  "p3130noauth|hatch-egress-proxy|3130|" \
  "p3128noauth|hatch-egress-proxy|3128|"
do
  IFS='|' read -r label ph pp pa <<< "$cand"
  [ -n "$ph" ] || continue
  [ -n "$pp" ] || continue
  res="$(pick "$ph" "$pp" "$pa" "$label" 2>/dev/null)"
  if [ -n "$res" ]; then
    CHOSEN="$res"
    break
  fi
done

if [ -z "$CHOSEN" ]; then
  echo "ts-socat-proxy: khong candidate nao CONNECT duoc" >&2
  exit 1
fi

IFS='|' read -r label PROXY_HOST PROXY_PORT PROXY_AUTH <<< "$CHOSEN"
auth=""
[ -n "$PROXY_AUTH" ] && auth=",proxyauth=${PROXY_AUTH}"

exec socat - "PROXY:${PROXY_HOST}:${TARGET_HOST}:${TARGET_PORT},proxyport=${PROXY_PORT}${auth}"
