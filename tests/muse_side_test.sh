#!/bin/bash
# ==============================================================================
# muse_side_test.sh - Kiem tra phia Muse offline (khong can container that):
#   1. Prompt VAN TAI ngan, co 4 buoc bang loi nguoi, KHONG chua ma nguon
#      (truong hop bi bo loc an toan cua Agent Muse chan).
#   2. Bundle phia Muse (muse_side.sh) chay dung: config + HELLO/REPORT.
#   3. Config tunnel RIENG theo port (2 port tren cung container khong dau nhau).
# ==============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/muse-side-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fails=0

# ok <label> <command...>  -- command exit 0 = PASS
ok() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  ok   - $label"
  else
    echo "  FAIL - $label"
    fails=$((fails + 1))
  fi
}

# rc <label> <exit-code>  -- 0 = PASS
rc() {
  if [ "$2" = "0" ]; then
    echo "  ok   - $1"
  else
    echo "  FAIL - $1"
    fails=$((fails + 1))
  fi
}

# count_json <dir> -- so file .json trong thu muc
count_json() {
  local dir="$1" n=0 f
  for f in "$dir"/*.json; do
    [ -f "$f" ] && n=$((n + 1))
  done
  echo "$n"
}

LOCAL_SPOOL="$TMP/local"
MUSE_HOME="$TMP/muse"
mkdir -p "$LOCAL_SPOOL" "$MUSE_HOME/.muse-bridge"

echo "== 1. prompt ngan, khong chua code"
python3 "$REPO_DIR/scripts/render_prompt.py" --host 100.64.0.1 --user testuser \
  --port 2223 --spool "$LOCAL_SPOOL" --out "$TMP/MUSE_PROMPT.md" >/dev/null
size=$(wc -c < "$TMP/MUSE_PROMPT.md")
ok "prompt ngan (<12KB, hien tai ${size}B)" test "$size" -lt 12000
ok "prompt khong nhung ma nguon" bash -c '! grep -q MUSE_BRIDGE_PY_EOF "$1"' _ "$TMP/MUSE_PROMPT.md"
ok "prompt co public key may ngoai" grep -q "ssh-ed25519" "$TMP/MUSE_PROMPT.md"
ok "prompt co port cua host" grep -q "2223" "$TMP/MUSE_PROMPT.md"
ok "prompt co dia chi may ngoai" grep -q "100.64.0.1" "$TMP/MUSE_PROMPT.md"
ok "prompt co buoc authorize key" grep -q "authorized_keys" "$TMP/MUSE_PROMPT.md"

echo "== 2. bundle phia Muse chay dung (config + HELLO/REPORT)"
cp "$REPO_DIR/bridge/bridge.py" "$MUSE_HOME/.muse-bridge/bridge.py"
cat > "$TMP/run_muse_side.sh" <<EOF
export MUSE_BRIDGE_LIB_ONLY=1
. "$REPO_DIR/bridge/muse_side.sh"
BASE="\$HOME/base"; KEY="\$BASE/keys/muse-agent-ed25519"
PROXY="\$BASE/tunnel/ts-socat-proxy.sh"; LOOP="\$BASE/tunnel/reverse-tunnel.sh"
mkdir -p "\$BASE/keys" "\$BASE/tunnel"
ssh-keygen -t ed25519 -f "\$KEY" -N "" -C "muse-external-agent" >/dev/null 2>&1
detect_loop; ensure_loop; write_tunnel_conf
write_config
bus send --type HELLO --subject "Muse da len" --body "toi day" >/dev/null
bus send --type REPORT --subject "Trang thai" --body-file - <<'BODY'
MUSE_HOST=test
MUSE_TUNNEL=ADOPTED
BODY
status_report
EOF
code=0
env MUSE_BRIDGE_STATE="$MUSE_HOME/.muse-bridge" \
    MUSE_BRIDGE_TRANSPORT=dir \
    MUSE_BRIDGE_PEER_SPOOL="$LOCAL_SPOOL" \
    HOME="$MUSE_HOME" \
    LOCAL_HOST=100.64.0.1 \
    LOCAL_USER=testuser \
    LOCAL_PORT=2223 \
    LOCAL_SPOOL="$LOCAL_SPOOL" \
    bash "$TMP/run_muse_side.sh" > "$TMP/out.txt" 2>&1 || code=$?
rc "bundle chay khong loi" "$code"

ok "may ngoai nhan duoc 2 tin (HELLO+REPORT)" test "$(count_json "$LOCAL_SPOOL/inbox")" = "2"
ok "co tin HELLO" grep -q '"type": "HELLO"' "$LOCAL_SPOOL"/inbox/*.json
ok "co tin REPORT" grep -q '"type": "REPORT"' "$LOCAL_SPOOL"/inbox/*.json

echo "== 3. config.json dung cau truc"
code=0
python3 - "$MUSE_HOME/.muse-bridge/config.json" <<'PY' || code=$?
import json, sys
cfg = json.load(open(sys.argv[1]))
assert cfg["role"] == "muse", cfg["role"]
assert cfg["peer"]["role"] == "local"
assert cfg["peer"]["transport"] == "dir", cfg["peer"]["transport"]
assert cfg["peer"]["host"] == "100.64.0.1"
assert cfg["peer"]["user"] == "testuser"
PY
rc "config.json hop le" "$code"

echo "== 4. loop script + config rieng cho port"
ok "config tunnel cho port 2223" grep -q 'REMOTE_PORT="2223"' "$MUSE_HOME/base/tunnel/tunnel-2223.conf"
ok "loop script rieng cho port 2223 ton tai" test -f "$MUSE_HOME/base/tunnel/reverse-tunnel-2223.sh"
ok "loop script doc config theo port (khong dung config chung)" \
  grep -q 'tunnel-\${PORT:-default}.conf' "$MUSE_HOME/base/tunnel/reverse-tunnel-2223.sh"
ok "loop script khong hard-code IP cua may nao" \
  bash -c '! grep -qE "100\.[0-9]+\.[0-9]+\.[0-9]+" "$1"' _ "$MUSE_HOME/base/tunnel/reverse-tunnel-2223.sh"

echo
if [ "$fails" = "0" ]; then echo "MUSE_SIDE_TEST: PASS"; else echo "MUSE_SIDE_TEST: FAIL ($fails)"; fi
exit "$fails"
