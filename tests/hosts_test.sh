#!/bin/bash
# ==============================================================================
# hosts_test.sh - Kiem tra dang ky nhieu Muse host (port, alias, spool, prompt).
# ==============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/muse-hosts-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

export MUSE_BRIDGE_STATE="$TMP/state"
export MUSE_BRIDGE_REPO_HOSTS="$TMP/repo-hosts"
export MUSE_URL="https://muse.ai/"

fails=0
check() { if [ "$2" = "0" ]; then echo "  ok   - $1"; else echo "  FAIL - $1"; fails=$((fails+1)); fi }

bash "$REPO_DIR/scripts/bridge.sh" add-host --host muse --port 2222 --label "Muse chinh" >/dev/null
bash "$REPO_DIR/scripts/bridge.sh" add-host --host muse2 --port 2223 --label "Muse thu 2" >/dev/null

echo "== 1. hosts li ke 2 host"
out="$(bash "$REPO_DIR/scripts/bridge.sh" hosts)"
echo "$out" | grep -q "^muse " 
check "co host muse" $?
echo "$out" | grep -q "^muse2 .*2223"
check "muse2 dung port 2223" $?
[ "$(echo "$out" | grep -cE '^(muse|muse2) ')" = "2" ]
check "khong trung lap host" $?

echo "== 2. config tung host tach biet"
python3 - "$MUSE_BRIDGE_STATE" <<'PY'
import json, os, sys
state = sys.argv[1]
a = json.load(open(os.path.join(state, "hosts", "muse.json")))
b = json.load(open(os.path.join(state, "hosts", "muse2.json")))
assert a["peer"]["port"] == 2222, a["peer"]["port"]
assert b["peer"]["port"] == 2223, b["peer"]["port"]
assert a["spool"] != b["spool"], (a["spool"], b["spool"])
assert a["peer"]["id"] == "muse" and b["peer"]["id"] == "muse2"
PY
check "port + spool rieng cho tung host" $?

echo "== 3. ssh alias trong ~/.ssh/config"
grep -q "^Host muse2$" "$HOME/.ssh/config"
check "co alias Host muse2" $?
grep -A3 "^Host muse2$" "$HOME/.ssh/config" | grep -q "Port 2223"
check "alias muse2 troi port 2223" $?

echo "== 4. prompt render dung cho host"
bash "$REPO_DIR/scripts/bridge.sh" prompt --host muse2 >/dev/null
prompt_file="$MUSE_BRIDGE_REPO_HOSTS/muse2/MUSE_PROMPT.md"
[ -s "$prompt_file" ]
check "da render prompt cho muse2" $?
grep -q "2223" "$prompt_file"
check "prompt chua port 2223" $?
python3 - "$MUSE_BRIDGE_REPO_HOSTS/muse2.json" <<'PY2'
import json, sys
card = json.load(open(sys.argv[1]))
assert "spools/muse2" in card["local_spool"], card["local_spool"]
assert card["tunnel_port"] == 2223, card
PY2
check "card luu dung spool + port rieng" $?

echo "== 5. bus doc dung config theo --host"
out="$(python3 "$REPO_DIR/bridge/bridge.py" --host muse2 status 2>&1)"
echo "$out" | grep -q "HOST_ID=muse2"
check "bridge.py --host muse2 dung config dung" $?

echo "== 6. tin nhan gan nhan host"
out="$(python3 "$REPO_DIR/bridge/bridge.py" --host muse2 send --type NOTE --subject "test" --body "x" 2>&1)"
echo "$out" | grep -q "host=muse2\|to=muse"
check "tin nhan gan host" $?

echo
if [ "$fails" = "0" ]; then echo "HOSTS_TEST: PASS"; else echo "HOSTS_TEST: FAIL ($fails)"; fi
exit "$fails"
