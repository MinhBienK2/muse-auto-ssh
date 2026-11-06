#!/bin/bash
# ==============================================================================
# muse_side_test.sh - Kiem tra phia Muse offline (khong can container that):
#   - bundle ghi ra tu MUSE_PROMPT.md chay dung
#   - config.json sinh ra dung
#   - HELLO/REPORT gui ve "may ngoai" (transport dir) that
#   - status_report in day du cac truong MUSE_*
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

echo "== 1. tach bundle tu MUSE_PROMPT.md (nhu khi dan prompt)"
python3 - "$REPO_DIR/MUSE_PROMPT.md" "$MUSE_HOME" <<'PY'
import re, sys
prompt, home = sys.argv[1], sys.argv[2]
text = open(prompt, encoding="utf-8").read()
blocks = re.findall(r"```bash\n(.*?)```", text, re.S)
block = blocks[0]
open(home + "/.muse-bridge/_prompt_block.sh", "w").write(block)
PY
[ -s "$MUSE_HOME/.muse-bridge/_prompt_block.sh" ]
check "tach duoc khoi prompt" $?

echo "== 2. viet 3 file bundle vao thu muc that"
python3 - "$REPO_DIR/MUSE_PROMPT.md" "$MUSE_HOME/.muse-bridge" <<'PY'
import re, sys
prompt, out = sys.argv[1], sys.argv[2]
text = open(prompt, encoding="utf-8").read()
block = re.findall(r"```bash\n(.*?)```", text, re.S)[0]
for marker, name in (("MUSE_BRIDGE_PY_EOF", "bridge.py"),
                      ("MUSE_SIDE_SH_EOF", "muse_side.sh"),
                      ("MUSE_INJECT_WD_EOF", "inject_watchdog.py")):
    start = block.index("cat > /root/.muse-bridge/%s <<'%s'" % (name, marker))
    body_start = block.index("\n", start) + 1
    body_end = block.index("\n%s" % marker, body_start)
    open("%s/%s" % (out, name), "w").write(block[body_start:body_end] + "\n")
PY
for f in bridge.py muse_side.sh inject_watchdog.py; do
  [ -s "$MUSE_HOME/.muse-bridge/$f" ]
  check "bundle $f duoc ghi" $?
done

echo "== 3. chay config + HELLO/REPORT (transport dir)"
MUSE_BRIDGE_STATE="$MUSE_HOME/.muse-bridge" \
MUSE_BRIDGE_TRANSPORT=dir \
MUSE_BRIDGE_PEER_SPOOL="$LOCAL_SPOOL" \
HOME="$MUSE_HOME" \
LOCAL_HOST=100.120.205.53 \
LOCAL_USER=minhbien \
LOCAL_SPOOL="$LOCAL_SPOOL" \
bash -c '
  export MUSE_BRIDGE_LIB_ONLY=1
  . '"$REPO_DIR"'/bridge/muse_side.sh
  BASE="$HOME/base"; KEY="$BASE/keys/muse-agent-ed25519"; PROXY="$BASE/tunnel/ts-socat-proxy.sh"; LOOP="$BASE/tunnel/reverse-tunnel.sh"
  mkdir -p "$BASE/keys" "$BASE/tunnel"
  ssh-keygen -t ed25519 -f "$KEY" -N "" -C "muse-external-agent" >/dev/null 2>&1
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

echo "== 4. status_report in day du truong"
for field in MUSE_HOST MUSE_BASE MUSE_KEY MUSE_PUBKEY MUSE_TUNNEL MUSE_PERSISTENCE MUSE_PROBE; do
  grep -q "^$field=" "$TMP/out.txt"
  check "status_report co $field" $?
done

echo "== 5. config.json dung cau truc"
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

echo
if [ "$fails" = "0" ]; then echo "MUSE_SIDE_TEST: PASS"; else echo "MUSE_SIDE_TEST: FAIL ($fails)"; fi
exit "$fails"
