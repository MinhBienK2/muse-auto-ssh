#!/bin/bash
# ==============================================================================
# banner_probe_test.sh - Kiem tra ts-connect-proxy.py --banner.
#
# Ly do can test: ban cu doc 4 byte roi DONG socket -> du lieu chua doc con
# lai trong buffer -> kernel gui RST -> sshd log
# "kex_exchange_identification: read: Connection reset by peer" (moi 5-15s).
# Nhieu nhieu nhat co the bi platform gan cell "sshd_banner_failed" ->
# flapping_backoff -> cell bi refresh (mat mot vong).
#
# Ban moi: doc TRON BO dong banner (den '\n') roi shutdown(SHUT_WR) -> FIN sach.
#
# Hermetic: server gia lap chay tren localhost, khong cham sshd that.
# ==============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROXY="$REPO_DIR/bridge/ts-connect-proxy.py"
TMP="$(mktemp -d /tmp/muse-banner-test.XXXXXX)"
trap 'rm -rf "$TMP"; [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null' EXIT

fails=0
check() { if [ "$2" = "0" ]; then echo "  ok   - $1"; else echo "  FAIL - $1"; fails=$((fails+1)); fi; }

# --- server gia lap: gui banner roi nho client doc het ----------------------
# Server ghi "reset" neu nhan duoc RST (ConnectionResetError khi recv).
cat > "$TMP/server.py" <<'PY'
import socket, sys, threading, time

port_file, mode, out_file = sys.argv[1], sys.argv[2], sys.argv[3]
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0))
srv.listen(1)
open(port_file, "w").write(str(srv.getsockname()[1]))

def serve():
    conn, _ = srv.accept()
    try:
        if mode == "slow":
            time.sleep(6)          # banner den rat cham
            conn.sendall(b"SSH-2.0-Slow\r\n")
        else:
            conn.sendall(b"SSH-2.0-OpenSSH_9.6\r\n")
        # Cho client doc het roi dung o giữa -> nếu client đóng sớm (chỉ đọc
        # 4 byte) thì server nhận RST.
        conn.settimeout(5)
        try:
            while True:
                data = conn.recv(64)
                if not data:
                    break
        except ConnectionResetError:
            open(out_file, "w").write("reset")
            return
        except socket.timeout:
            pass
        open(out_file, "w").write("clean")
    finally:
        conn.close()

threading.Thread(target=serve, daemon=True).start()
time.sleep(12)
PY

# --- 1) banner den -> in ra dung dong, va KHONG co RST ------------------------
SRV_PID=""
python3 "$TMP/server.py" "$TMP/port" fast "$TMP/out1" &
SRV_PID=$!
for _ in $(seq 1 40); do [ -s "$TMP/port" ] && break; sleep 0.1; done
PORT1="$(cat "$TMP/port" 2>/dev/null || true)"
if [ -n "$PORT1" ]; then
  out="$(timeout 10 python3 "$PROXY" --banner 127.0.0.1 "$PORT1" 2>/dev/null)"
  case "$out" in
    *SSH-2.0-OpenSSH*) check "in ra duoc dong banner SSH" 0 ;;
    *) check "in ra duoc dong banner SSH" 1 ;;
  esac
  # doi server de bao server nhin thay phia client
  for _ in $(seq 1 40); do [ -s "$TMP/out1" ] && break; sleep 0.1; done
  res="$(cat "$TMP/out1" 2>/dev/null || true)"
  if [ "$res" = "clean" ]; then
    check "dong ket bang FIN (khong RST -> sshd khong log connection reset)" 0
  else
    check "dong ket bang FIN (khong RST -> sshd khong log connection reset)" 1
  fi
else
  check "server gia lap len" 1
fi
kill "$SRV_PID" 2>/dev/null; SRV_PID=""

# --- 2) server treo (banner den cham) -> probe timeout, khong treo vo han ----
python3 "$TMP/server.py" "$TMP/port2" slow "$TMP/out2" &
SRV_PID=$!
for _ in $(seq 1 40); do [ -s "$TMP/port2" ] && break; sleep 0.1; done
PORT2="$(cat "$TMP/port2" 2>/dev/null || true)"
if [ -n "$PORT2" ]; then
  start=$(date +%s)
  out="$(timeout 20 python3 "$PROXY" --banner 127.0.0.1 "$PORT2" 2>/dev/null)"
  rc=$?
  dur=$(( $(date +%s) - start ))
  # Server treo: probe phai BAO LOI nhanh (khong treo, khong in banner sai)
  # chứ không phải treo đến hết timeout ngoài.
  if [ "$rc" != "0" ] && [ "$rc" != "124" ]; then
    check "server treo: probe bao loi nhanh (khong treo vo han)" 0
  else
    check "server treo: probe bao loi nhanh (khong treo vo han)" 1
  fi
  if [ -z "$out" ]; then
    check "server treo: khong in ra banner sai" 0
  else
    check "server treo: khong in ra banner sai" 1
  fi
  if [ "$dur" -le 15 ]; then
    check "server treo: probe ket thuc trong <=15s" 0
  else
    check "server treo: probe ket thuc trong <=15s" 1
  fi
else
  check "server treo len" 1
fi
kill "$SRV_PID" 2>/dev/null; SRV_PID=""

echo
if [ "$fails" = "0" ]; then echo "BANNER_TEST: PASS"; else echo "BANNER_TEST: FAIL ($fails)"; fi
exit "$fails"
