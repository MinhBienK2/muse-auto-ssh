#!/bin/bash
# ==============================================================================
# tunnel_loop_test.sh - Kiem tra vong lap tunnel (reverse-tunnel.sh) va proxy
# helper (ts-socat-proxy.sh) hoat dong dung, khong can container that.
#
#   bash tests/tunnel_loop_test.sh
#
# Kiem tra:
#   1) vong lap tu MOC TUNNEL (khong can supervisor ben ngoai).
#   2) vong lap TU DUNG LAI tunnel khi tien trinh ssh chet.
#   3) vong lap goi lai sshd (SSHD_BIN) de sshd khong chet im lang.
#   4) proxy helper noi TRUC TIEP truoc, khong can HTTP CONNECT proxy.
#
# Moi lan chay deu dung stub (ssh/sshd/pkill/pgrep) -> khong cham sshd that
# cua may dang chay test.
# ==============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/muse-tunnel-test.XXXXXX)"
LOOP_PID=""
cleanup() {
  [ -n "$LOOP_PID" ] && kill "$LOOP_PID" 2>/dev/null
  pkill -f "$TMP/stub/ssh" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

fails=0
check() { if [ "$2" = "0" ]; then echo "  ok   - $1"; else echo "  FAIL - $1"; fails=$((fails+1)); fi; }

# --- stubs -------------------------------------------------------------------
STUB="$TMP/stub"; mkdir -p "$STUB"
# ssh: ghi args ra file, song mot khoang ngan roi thoat (dung de kiem tra
# vong lap tu dong lai no).
cat > "$STUB/ssh" <<EOF
#!/bin/bash
echo "\$*" >> "$TMP/ssh.calls"
# len "pull bundle" phai tra loi ngay (khong treo), con lenh mo tunnel moi
# giu tiep de vong lap kiem tra co tu mo lai no khong.
case "\$*" in
  *"bundle/VERSION"*|*"bundle"*"tar cf"*) exit 0 ;;
esac
sleep "\${STUB_SSH_TTL:-3600}"
EOF
chmod +x "$STUB/ssh"
# sshd stub: chi danh dau da chay (khong mo cong that)
cat > "$STUB/sshd-stub" <<EOF
#!/bin/bash
echo "\$*" >> "$TMP/sshd.calls"
touch "$TMP/sshd.marker"
EOF
chmod +x "$STUB/sshd-stub"
# pkill stub: KHONG giet gi ca (test chay tren may co sshd that)
printf '#!/bin/sh\nexit 0\n' > "$STUB/pkill"; chmod +x "$STUB/pkill"
# pgrep stub: "-x sshd" -> theo marker; con lai -> pgrep that
cat > "$STUB/pgrep" <<EOF
#!/bin/bash
for a in "\$@"; do
  if [ "\$a" = "sshd" ]; then
    [ -f "$TMP/sshd.marker" ] && exit 0
    exit 1
  fi
done
exec /usr/bin/pgrep "\$@"
EOF
chmod +x "$STUB/pgrep"

# --- 1-3) vong lap ------------------------------------------------------------
PORT=9999
TUN="$TMP/tunnel"; mkdir -p "$TUN"
cp "$REPO_DIR/bridge/reverse-tunnel.sh" "$TUN/reverse-tunnel-$PORT.sh"
cat > "$TUN/tunnel-$PORT.conf" <<EOF
LOCAL_IP="127.0.0.1"
LOCAL_USER="testuser"
REMOTE_PORT="$PORT"
KEY_PATH="$TUN/fake_key"
PROXY_PATH="$STUB/proxy-stub"
TUNNEL_LOG="$TUN/tunnel.log"
EOF
printf '#!/bin/sh\nexit 0\n' > "$STUB/proxy-stub"; chmod +x "$STUB/proxy-stub"

PATH="$STUB:$PATH" SSHD_BIN="$STUB/sshd-stub" STUB_SSH_TTL=6 \
  bash "$TUN/reverse-tunnel-$PORT.sh" >"$TUN/loop.out" 2>&1 &
LOOP_PID=$!

sleep 4
if [ -s "$TMP/ssh.calls" ]; then res=0; else res=1; fi
check "vong lap tu moc tunnel (khong can supervisor ben ngoai)" "$res"
grep -q -- "-R $PORT:127.0.0.1:22" "$TMP/ssh.calls"
check "tunnel dung co -R dung cong $PORT" $?
if [ -f "$TMP/sshd.marker" ]; then res=0; else res=1; fi
check "vong lap kiem tra sshd qua SSHD_BIN" "$res"

# stub ssh chet sau 6s -> vong lap phai tu mo lai
sleep 14
calls_after="$(wc -l < "$TMP/ssh.calls")"
if [ "$calls_after" -ge 2 ]; then res=0; else res=1; fi
check "vong lap tu mo lai tunnel khi tien trinh ssh chet" "$res"
if [ -s "$TUN/tunnel.log" ]; then res=0; else res=1; fi
check "loop ghi log vao tunnel.log" "$res"

kill "$LOOP_PID" 2>/dev/null
wait "$LOOP_PID" 2>/dev/null
LOOP_PID=""

# --- 4) proxy helper noi truc tiep -------------------------------------------
python3 - "$TMP" <<'PY' &
import socket, sys, threading, time
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0))
srv.listen(1)
port = srv.getsockname()[1]
open(sys.argv[1] + "/echo.port", "w").write(str(port))

def serve():
    while True:
        conn, _ = srv.accept()
        try:
            data = conn.recv(64)
            if data:
                conn.sendall(b"PONG:" + data)
        except OSError:
            pass
        conn.close()

threading.Thread(target=serve, daemon=True).start()
time.sleep(8)
PY
PY_PID=$!
sleep 1.5
EPORT="$(cat "$TMP/echo.port" 2>/dev/null)"
if [ -n "$EPORT" ]; then
  out="$(printf 'ping' | timeout 6 bash "$REPO_DIR/bridge/ts-socat-proxy.sh" 127.0.0.1 "$EPORT" 2>/dev/null)"
  if [ "$out" = "PONG:ping" ]; then res=0; else res=1; fi
  check "proxy helper noi truc tiep (khong can HTTP CONNECT proxy)" "$res"
else
  check "proxy helper noi truc tiep (khong can HTTP CONNECT proxy)" 1
fi
kill "$PY_PID" 2>/dev/null

# --- 5) duong truc tiep phai duoc thu TRUOC, proxy la duong cuu --------------
# Container noi thang duoc qua tailscale rieng (~3s); buoc trung gian Hatch hay
# treo o "banner exchange". Neu doi thu tu, tunnel se cham.
cat > "$STUB/socat" <<EOF
#!/bin/bash
echo "\$*" >> "$TMP/socat.calls"
exit 0
EOF
chmod +x "$STUB/socat"
out="$(printf 'ping' | PATH="$STUB:$PATH" timeout 10 bash "$REPO_DIR/bridge/ts-socat-proxy.sh" 127.0.0.1 65000 2>/dev/null)"
[ -s "$TMP/socat.calls" ]
check "khi noi truc tiep that bai thi moi dung den proxy (duong cuu)" $?
[ -z "$out" ]
check "duong cuu khong ghi them du lieu lung tung" $?

echo
if [ "$fails" = "0" ]; then echo "TUNNEL_TEST: PASS"; else echo "TUNNEL_TEST: FAIL ($fails)"; fi
exit "$fails"
