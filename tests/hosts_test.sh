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
# tailscale gia -> may khong cai tailscale (CI runner, may moi) van chay duoc
mkdir -p "$TMP/bin"
cat > "$TMP/bin/tailscale" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "ip" ]; then echo "100.64.0.1"; exit 0; fi
exit 1
EOF
chmod +x "$TMP/bin/tailscale"
export PATH="$TMP/bin:$PATH"
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

# rc_nonzero <label> <exit-code>  -- exit != 0 = PASS (truong hop loi)
rc_nonzero() {
  if [ "$2" != "0" ]; then
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
python3 - "$MUSE_BRIDGE_REPO_HOSTS/muse2/card.json" <<'PY2' || code=$?
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

echo "== 7. set-port: doi port ma KHONG ghi lai card"
# add-host ghi lai card tu dau -> mat 'thread' va reset profile ve Default.
# set-port chi sua config + card.tunnel_port + ssh alias.
python3 - "$MUSE_BRIDGE_REPO_HOSTS/muse2/card.json" <<'PY0'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
c["thread"] = "https://muse.ai/t/abc123"
c["web_profile_dir"] = "Profile 2"
json.dump(c, open(p, "w"), indent=2)
PY0
bash "$REPO_DIR/scripts/bridge.sh" set-port --host muse2 --port 2299 >/dev/null
code=0
python3 - "$MUSE_BRIDGE_STATE" "$MUSE_BRIDGE_REPO_HOSTS/muse2/card.json" <<'PY' || code=$?
import json, os, sys
state, card_path = sys.argv[1], sys.argv[2]
cfg = json.load(open(os.path.join(state, "hosts", "muse2.json")))
assert cfg["peer"]["port"] == 2299, cfg["peer"]["port"]
card = json.load(open(card_path))
assert card["tunnel_port"] == 2299, card
# truong quan trong phai con nguyen
assert card["thread"] == "https://muse.ai/t/abc123", card
assert card["web_profile_dir"] == "Profile 2", card
PY
rc "config+card doi port, giu thread va profile" "$code"
ok "ssh alias doi theo port moi" bash -c 'grep -A3 "^Host muse2$" "$1" | grep -q "Port 2299"' _ "$HOME/.ssh/config"
ok "bus doc port moi" bash -c 'python3 "$1/bridge/bridge.py" --host muse2 status 2>&1 | grep -q "PEER=.*:2299"' _ "$REPO_DIR"
out="$(bash "$REPO_DIR/scripts/bridge.sh" set-port --host muse2 2>&1)"; rc_nonzero "thieu --port -> exit khac 0" "$?"
out="$(bash "$REPO_DIR/scripts/bridge.sh" set-port --host khong-co --port 2299 2>&1)"; rc_nonzero "host khong ton tai -> exit khac 0" "$?"

echo "== 8. rename: doi id theo chuan muse-<email>, giu port/thread/tin nhan"
mkdir -p "$MUSE_BRIDGE_STATE/spools/muse2/inbox"
echo '{"id":"giu-lai"}' > "$MUSE_BRIDGE_STATE/spools/muse2/inbox/tin-cu.json"
bash "$REPO_DIR/scripts/bridge.sh" rename --host muse2 --new-id muse-minh >/dev/null
code=0
python3 - "$MUSE_BRIDGE_STATE" "$MUSE_BRIDGE_REPO_HOSTS" <<'PY3' || code=$?
import json, os, sys
state, repo = sys.argv[1:3]
cfg = json.load(open(os.path.join(state, "hosts", "muse-minh.json")))
assert cfg["id"] == "muse-minh" and cfg["peer"]["id"] == "muse-minh", cfg
assert cfg["peer"]["port"] == 2299, cfg["peer"]["port"]
assert cfg["spool"].endswith("/spools/muse-minh"), cfg["spool"]
assert not os.path.exists(os.path.join(state, "hosts", "muse2.json"))
assert not os.path.exists(os.path.join(state, "spools", "muse2"))
assert os.path.isfile(os.path.join(state, "spools", "muse-minh", "inbox", "tin-cu.json"))
card = json.load(open(os.path.join(repo, "muse-minh", "card.json")))
assert card["id"] == "muse-minh" and card["ssh_alias"] == "muse-minh", card
assert card["thread"] == "https://muse.ai/t/abc123", card
assert card["web_profile_dir"] == "Profile 2", card
assert card["tunnel_port"] == 2299, card
assert not os.path.exists(os.path.join(repo, "muse2"))
assert not os.path.exists(os.path.join(repo, "muse2.json"))
PY3
rc "config+spool+card doi id, giu port/thread/profile/tin cu" "$code"
ok "ssh alias moi tro dung port" bash -c 'grep -A3 "^Host muse-minh$" "$1" | grep -q "Port 2299"' _ "$HOME/.ssh/config"
ok "alias cu da go" bash -c '! grep -q "^Host muse2$" "$1"' _ "$HOME/.ssh/config"
ok "alias host khac khong bi anh huong" grep -q "^Host muse$" "$HOME/.ssh/config"
ok "default-host cua host khac giu nguyen" bash -c '[ "$(cat "$1/default-host")" = "muse" ]' _ "$MUSE_BRIDGE_STATE"
echo muse-minh > "$MUSE_BRIDGE_STATE/default-host"
bash "$REPO_DIR/scripts/bridge.sh" rename --host muse-minh --new-id muse-tam >/dev/null
ok "default-host doi theo khi trung host bi rename" bash -c '[ "$(cat "$1/default-host")" = "muse-tam" ]' _ "$MUSE_BRIDGE_STATE"
out="$(bash "$REPO_DIR/scripts/bridge.sh" rename --host muse-tam --new-id muse 2>&1)"; rc_nonzero "id moi da ton tai -> exit khac 0" "$?"
out="$(bash "$REPO_DIR/scripts/bridge.sh" rename --host muse-tam --new-id 'Ten Xau!' 2>&1)"; rc_nonzero "id chua ky tu la -> exit khac 0" "$?"

echo "== 9. remove-host: go dang ky, giu spool + lich su card"
bash "$REPO_DIR/scripts/bridge.sh" remove-host --host muse-tam >/dev/null
ok "config da go" bash -c '[ ! -f "$1/hosts/muse-tam.json" ]' _ "$MUSE_BRIDGE_STATE"
ok "alias da go" bash -c '! grep -q "^Host muse-tam$" "$1"' _ "$HOME/.ssh/config"
ok "spool tin nhan giu nguyen" bash -c '[ -f "$1/spools/muse-tam/inbox/tin-cu.json" ]' _ "$MUSE_BRIDGE_STATE"
ok "card thanh .removed (giu lich su)" bash -c '[ -f "$1/muse-tam.removed/card.json" ] && [ ! -d "$1/muse-tam" ]' _ "$MUSE_BRIDGE_REPO_HOSTS"
ok "default-host bi trung da xoa" bash -c '[ ! -f "$1/default-host" ]' _ "$MUSE_BRIDGE_STATE"
ok "host khac khong bi anh huong" bash -c '[ -f "$1/hosts/muse.json" ]' _ "$MUSE_BRIDGE_STATE"
out="$(bash "$REPO_DIR/scripts/bridge.sh" remove-host --host khong-co 2>&1)"; rc_nonzero "host khong ton tai -> exit khac 0" "$?"

echo "== 10. moi host lay CDP port rieng (khong dung chung Chrome -> dan nham account)"
bash "$REPO_DIR/scripts/bridge.sh" add-host --host muse-p2 --port 2230 --profile-dir "Profile 2" >/dev/null
bash "$REPO_DIR/scripts/bridge.sh" add-host --host muse-p3 --port 2231 --profile-dir "Profile 3" >/dev/null
code=0
python3 - "$MUSE_BRIDGE_REPO_HOSTS" <<'PY4' || code=$?
import json, os, sys
repo = sys.argv[1]
a = json.load(open(os.path.join(repo, "muse-p2", "card.json")))
b = json.load(open(os.path.join(repo, "muse-p3", "card.json")))
assert a["web_cdp_port"] != b["web_cdp_port"], (a["web_cdp_port"], b["web_cdp_port"])
assert a["web_clone_dir"] != b["web_clone_dir"], (a["web_clone_dir"], b["web_clone_dir"])
PY4
rc "2 host khac profile -> 2 CDP port khac nhau" "$code"

echo
if [ "$fails" = "0" ]; then echo "HOSTS_TEST: PASS"; else echo "HOSTS_TEST: FAIL ($fails)"; fi
exit "$fails"
