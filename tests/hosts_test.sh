#!/bin/bash
# ==============================================================================
# hosts_test.sh - Kiem tra dang ky nhieu Muse host (port, alias, spool, prompt).
#
# Hermetic: dung HOME tam nen KHONG doc/ghi ~/.ssh/config that cua nguoi dung.
# ==============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/muse-hosts-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
mkdir -p "$HOME/.ssh"
# key gia de render_prompt.py co public key (khong can key that cua may that)
ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N "" -C "muse-hosts-test" >/dev/null 2>&1
export MUSE_BRIDGE_STATE="$TMP/state"
export MUSE_BRIDGE_REPO_HOSTS="$TMP/repo-hosts"
export MUSE_URL="https://muse.ai/"

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

bash "$REPO_DIR/scripts/bridge.sh" add-host --host muse --port 2222 --label "Muse chinh" >/dev/null
bash "$REPO_DIR/scripts/bridge.sh" add-host --host muse2 --port 2223 --label "Muse thu 2" >/dev/null

echo "== 1. hosts li ke 2 host"
out="$(bash "$REPO_DIR/scripts/bridge.sh" hosts)"
ok "co host muse" grep -q "^muse " <<<"$out"
ok "muse2 dung port 2223" grep -q "^muse2 .*2223" <<<"$out"
ok "khong trung lap host" test "$(grep -cE '^(muse|muse2) ' <<<"$out")" = "2"

echo "== 2. config tung host tach biet"
code=0
python3 - "$MUSE_BRIDGE_STATE" <<'PY' || code=$?
import json, os, sys
state = sys.argv[1]
a = json.load(open(os.path.join(state, "hosts", "muse.json")))
b = json.load(open(os.path.join(state, "hosts", "muse2.json")))
assert a["peer"]["port"] == 2222, a["peer"]["port"]
assert b["peer"]["port"] == 2223, b["peer"]["port"]
assert a["spool"] != b["spool"], (a["spool"], b["spool"])
assert a["peer"]["id"] == "muse" and b["peer"]["id"] == "muse2"
PY
rc "port + spool rieng cho tung host" "$code"

echo "== 3. ssh alias trong ~/.ssh/config"
ok "co alias Host muse2" grep -q "^Host muse2$" "$HOME/.ssh/config"
ok "alias muse2 troi port 2223" bash -c 'grep -A3 "^Host muse2$" "$1" | grep -q "Port 2223"' _ "$HOME/.ssh/config"

echo "== 4. prompt render dung cho host"
bash "$REPO_DIR/scripts/bridge.sh" prompt --host muse2 >/dev/null
prompt_file="$MUSE_BRIDGE_REPO_HOSTS/muse2/MUSE_PROMPT.md"
ok "da render prompt cho muse2" test -s "$prompt_file"
ok "prompt chua port 2223" grep -q "2223" "$prompt_file"
code=0
python3 - "$MUSE_BRIDGE_REPO_HOSTS/muse2.json" <<'PY2' || code=$?
import json, sys
card = json.load(open(sys.argv[1]))
assert "spools/muse2" in card["local_spool"], card["local_spool"]
assert card["tunnel_port"] == 2223, card
PY2
rc "card luu dung spool + port rieng" "$code"

echo "== 5. bus doc dung config theo --host"
out="$(python3 "$REPO_DIR/bridge/bridge.py" --host muse2 status 2>&1)"
ok "bridge.py --host muse2 dung config dung" grep -q "HOST_ID=muse2" <<<"$out"

echo "== 6. tin nhan gan nhan host"
out="$(python3 "$REPO_DIR/bridge/bridge.py" --host muse2 send --type NOTE --subject "test" --body "x" 2>&1)"
ok "tin nhan gan host" grep -q "host=muse2\|to=muse" <<<"$out"

echo
if [ "$fails" = "0" ]; then echo "HOSTS_TEST: PASS"; else echo "HOSTS_TEST: FAIL ($fails)"; fi
exit "$fails"
