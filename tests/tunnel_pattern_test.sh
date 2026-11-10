#!/bin/bash
# ==============================================================================
# tunnel_pattern_test.sh - Kiem tra pattern phat hien tunnel khop voi moi
# thu tu flag cua lenh ssh.
#
# Van de goc (phat hien tren container that): watchdog dung
#   pgrep -f "ssh -N -R <port>:..."
# nen KHONG khop lenh ssh that co -i KEY dat truoc -N
#   ssh -i /path/key -N -R 2224:127.0.0.1:22 user@host
# -> watchdog tu spawn them, hai supervisor tranh cung port forward,
#    container bao "remote port forwarding failed for listen port 2224".
#
# Hermetic: chay pgrep that tren cac process thu nghiem (sleep), khong cham
# container that.
# ==============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/muse-tunnel-pattern.XXXXXX)"
trap 'rm -rf "$TMP"; kill %1 %2 2>/dev/null' EXIT

fails=0
ok() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  ok   - $label"
  else
    echo "  FAIL - $label"
    fails=$((fails + 1))
  fi
}

PORT=2224

echo "== 1. pattern moi khop lenh co -i KEY truoc -N"
# (dung `exec -a` de doi argv[0] -> cmdline giong het lenh ssh that)
bash -c 'exec -a "ssh -i /home/hatch/.ssh/id_ed25519 -N -R 2224:127.0.0.1:22 -o ProxyCommand=x minhbien@100.120.205.53" sleep 60' &
P1=$!
sleep 1
ok "khop lenh co -i KEY truoc -N" pgrep -f -- "-R ${PORT}:127.0.0.1:22"
if pgrep -f "ssh -N -R ${PORT}:" >/dev/null 2>&1; then res=0; else res=1; fi
if [ "$res" = "1" ]; then
  echo "  ok   - pattern CU that bai voi lenh nay (chung minh bug)"
else
  echo "  FAIL - pattern CU van khop - khong chung minh duoc bug"
  fails=$((fails + 1))
fi
kill $P1 2>/dev/null
wait $P1 2>/dev/null

echo "== 2. pattern moi khop lenh co -N truoc -R"
bash -c 'exec -a "ssh -N -R 2224:127.0.0.1:22 -o ProxyCommand=y minhbien@100.120.205.53" sleep 60' &
P2=$!
sleep 1
ok "khop lenh co -N truoc -R" pgrep -f -- "-R ${PORT}:127.0.0.1:22"
kill $P2 2>/dev/null
wait $P2 2>/dev/null

echo "== 3. code trong repo dung pattern moi"
ok "reverse-tunnel.sh dung -R <port>:127.0.0.1:22" \
  grep -q -- '-R ${REMOTE_PORT}:127.0.0.1:22' "$REPO_DIR/bridge/reverse-tunnel.sh"
ok "reverse-tunnel.sh khong con 'ssh -N -R' trong pgrep" \
  bash -c '! grep -q "pgrep -f \"ssh -N -R" "$1"' _ "$REPO_DIR/bridge/reverse-tunnel.sh"
ok "muse_side.sh khong con 'ssh -N -R' trong pgrep" \
  bash -c '! grep -q "pgrep -f .ssh -N -R" "$1"' _ "$REPO_DIR/bridge/muse_side.sh"
ok "inject_watchdog.py khong con 'ssh -N -R' trong pgrep" \
  bash -c '! grep -q "pgrep -f .ssh -N -R" "$1"' _ "$REPO_DIR/bridge/inject_watchdog.py"

echo "== 4. khong khop nhầm sang port khac"
bash -c 'exec -a "ssh -N -R 2225:127.0.0.1:22 -o X=1 user@host" sleep 60' &
P3=$!
bash -c 'exec -a "ssh -i /k -N -R 2224:127.0.0.1:22 -o X=1 user@host" sleep 60' &
P4=$!
sleep 1
if pgrep -f -- "-R ${PORT}:127.0.0.1:22" >/dev/null 2>&1; then res=0; else res=1; fi
if [ "$res" = "0" ]; then
  echo "  ok   - van khop process dung port $PORT"
else
  echo "  FAIL - mat process dung port $PORT"
  fails=$((fails + 1))
fi
kill $P3 $P4 2>/dev/null
wait $P3 $P4 2>/dev/null

echo
if [ "$fails" = "0" ]; then echo "TUNNEL_PATTERN_TEST: PASS"; else echo "TUNNEL_PATTERN_TEST: FAIL ($fails)"; fi
exit "$fails"
