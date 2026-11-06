#!/bin/bash
# ==============================================================================
# muse_side_test.sh - Kiem tra phia Muse offline (khong can container that):
#   1. Prompt VAN TAI ngan, co 4 buoc bang loi nguoi, KHONG chua ma nguon
#      (truong hop bi bo loc an toan cua Agent Muse chan).
#   2. Bundle phia Muse (muse_side.sh) chay dung: config + HELLO/REPORT.
# ==============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/muse-side-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fails=0
check() { if [ "$2" = "0" ]; then echo "  ok   - $1"; else echo "  FAIL - $1"; fails=$((fails+1)); fi }

LOCAL_SPOOL="$TMP/local"
MUSE_HOME="$TMP/muse"
mkdir -p "$LOCAL_SPOOL" "$MUSE_HOME/.muse-bridge"

echo "== 1. prompt ngan, khong chua code"
python3 "$REPO_DIR/scripts/render_prompt.py" --host 100.120.205.53 --user minhbien \
  --port 2223 --spool "$LOCAL_SPOOL" --out "$TMP/MUSE_PROMPT.md" >/dev/null
size=$(wc -c < "$TMP/MUSE_PROMPT.md")
[ "$size" -lt 12000 ]
check "prompt ngan (<12KB, hien tai ${size}B)" $?
grep -q "MUSE_BRIDGE_PY_EOF" "$TMP/MUSE_PROMPT.md"
if [ $? -eq 0 ]; then echo "  FAIL - prompt van chua code nhung"; fails=$((fails+1)); else echo "  ok   - prompt khong nhung ma nguon"; fi
grep -q "ssh-ed25519" "$TMP/MUSE_PROMPT.md"
check "prompt co public key may ngoai" $?
grep -q "2223" "$TMP/MUSE_PROMPT.md"
check "prompt co port cua host" $?
grep -q "100.120.205.53" "$TMP/MUSE_PROMPT.md"
check "prompt co dia chi may ngoai" $?
grep -q "authorized_keys" "$TMP/MUSE_PROMPT.md"
check "prompt co buoc authorize key" $?

echo "== 2. bundle phia Muse chay dung (config + HELLO/REPORT)"
cp "$REPO_DIR/bridge/bridge.py" "$MUSE_HOME/.muse-bridge/bridge.py"
MUSE_BRIDGE_STATE="$MUSE_HOME/.muse-bridge" \
MUSE_BRIDGE_TRANSPORT=dir \
MUSE_BRIDGE_PEER_SPOOL="$LOCAL_SPOOL" \
HOME="$MUSE_HOME" \
LOCAL_HOST=100.120.205.53 \
LOCAL_USER=minhbien \
LOCAL_PORT=2223 \
LOCAL_SPOOL="$LOCAL_SPOOL" \
bash -c '
  export MUSE_BRIDGE_LIB_ONLY=1
  . '"$REPO_DIR"'/bridge/muse_side.sh
  BASE="$HOME/base"; KEY="$BASE/keys/muse-agent-ed25519"; PROXY="$BASE/tunnel/ts-socat-proxy.sh"; LOOP="$BASE/tunnel/reverse-tunnel.sh"
  mkdir -p "$BASE/keys" "$BASE/tunnel"
  ssh-keygen -t ed25519 -f "$KEY" -N "" -C "muse-external-agent" >/dev/null 2>&1
  detect_loop; ensure_loop
  write_config
  bus send --type HELLO --subject "Muse da len" --body "toi day" >/dev/null
  bus send --type REPORT --subject "Trang thai" --body-file - <<EOF
MUSE_HOST=test
MUSE_TUNNEL=ADOPTED
EOF
  status_report
' > "$TMP/out.txt" 2>&1
rc=$?
check "bundle chay khong loi (rc=$rc)" $?

n=$(ls "$LOCAL_SPOOL/inbox" 2>/dev/null | grep -c '\.json$')
[ "$n" = "2" ]
check "may ngoai nhan duoc 2 tin (HELLO+REPORT)" $?
grep -q '"type": "HELLO"' "$LOCAL_SPOOL"/inbox/*.json
check "co tin HELLO" $?
grep -q '"type": "REPORT"' "$LOCAL_SPOOL"/inbox/*.json
check "co tin REPORT" $?

echo "== 3. config.json dung cau truc"
python3 - "$MUSE_HOME/.muse-bridge/config.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
assert cfg["role"] == "muse", cfg["role"]
assert cfg["peer"]["role"] == "local"
assert cfg["peer"]["transport"] == "dir", cfg["peer"]["transport"]
assert cfg["peer"]["host"] == "100.120.205.53"
assert cfg["peer"]["user"] == "minhbien"
PY
check "config.json hop le" $?

echo "== 4. loop script rieng cho port"
grep -q "REMOTE_PORT=\"2223\"" "$MUSE_HOME/base/tunnel/reverse-tunnel-2223.sh" 2>/dev/null
check "loop script dung port 2223" $?

echo
if [ "$fails" = "0" ]; then echo "MUSE_SIDE_TEST: PASS"; else echo "MUSE_SIDE_TEST: FAIL ($fails)"; fi
exit "$fails"
