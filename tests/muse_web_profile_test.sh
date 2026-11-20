#!/bin/bash
# ==============================================================================
# muse_web_profile_test.sh - Kiem tra driver web clone dung Chrome profile.
#
# Van de goc: clone_profile chi lay "Default" -> host dung account khac
# (Chrome profile "Profile 2"...) se mo Chrome voi sai session.
#
# Hermetic: chi dung thu muc tam, khong cham vao Chrome that.
# ==============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/muse-web-profile-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

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

# Tao gia Chrome profile: hai thu muc "Default" va "Profile 2", moi thu muc
# co Cookies rieng de phan biet duoc vong clone.
make_profile() {
  local src="$1"
  mkdir -p "$src/Default" "$src/Profile 2"
  echo '{"name":"Default"}' > "$src/Default/Preferences"
  echo '{"name":"Profile 2"}' > "$src/Profile 2/Preferences"
  printf 'DEFAULT_COOKIE' > "$src/Default/Cookies"
  printf 'PROFILE2_COOKIE' > "$src/Profile 2/Cookies"
  printf '{}' > "$src/Local State"
}

clone() {  # clone <src> <dst> <profile-dir>
  python3 - "$REPO_DIR" "$1" "$2" "$3" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/bridge")
import muse_web
muse_web.clone_profile(sys.argv[2], sys.argv[3], sys.argv[4])
PY
}

echo "== 1. clone 'Profile 2' lay dung cookie cua profile do"
make_profile "$TMP/src"
clone "$TMP/src" "$TMP/dst2" "Profile 2"
ok "clone giu TEN thu muc profile (khong doi thanh Default)" test -d "$TMP/dst2/Profile 2"
ok "cookie cua Profile 2 duoc copy" grep -q "PROFILE2_COOKIE" "$TMP/dst2/Profile 2/Cookies"
ok "cookie cua Default khong lan sang" bash -c '! grep -q DEFAULT_COOKIE "$1"' _ "$TMP/dst2/Profile 2/Cookies"
ok "Local State duoc copy" test -f "$TMP/dst2/Local State"

echo "== 2. mac dinh van la Default (backward compatible)"
clone "$TMP/src" "$TMP/dst1" "Default"
ok "cookie cua Default duoc copy" grep -q "DEFAULT_COOKIE" "$TMP/dst1/Default/Cookies"
ok "cookie cua Profile 2 khong lan sang" bash -c '! grep -q PROFILE2_COOKIE "$1"' _ "$TMP/dst1/Default/Cookies"

echo "== 3. clone dir da ton tai -> khong ghi de (idempotent)"
printf 'KEEP_ME' > "$TMP/dst2/Profile 2/Cookies"
clone "$TMP/src" "$TMP/dst2" "Profile 2"
ok "khong ghi de clone dir cu" grep -q "KEEP_ME" "$TMP/dst2/Profile 2/Cookies"

echo "== 4. CLI chap nhan --profile-dir"
out="$(python3 "$REPO_DIR/bridge/muse_web.py" --help 2>&1)"
ok "co co --profile-dir" grep -q -- "--profile-dir" <<<"$out"

echo "== 4b. Chrome duoc mo voi --profile-directory dung ten profile"
code=0
python3 - "$REPO_DIR" <<'PY2' || code=$?
import sys
sys.path.insert(0, sys.argv[1] + "/bridge")
import muse_web, inspect
src = inspect.getsource(muse_web.ensure_chrome)
assert '--profile-directory=%s' in src, "thieu --profile-directory"
assert '"--user-data-dir=%s" % clone_dir' in src
PY2
if [ "$code" = "0" ]; then echo "  ok   - ensure_chrome truyen --profile-directory"; else echo "  FAIL - ensure_chrome truyen --profile-directory"; fails=$((fails + 1)); fi

echo "== 5. add-host luu profile web rieng theo host"
STATE="$TMP/state"
REPO_HOSTS="$TMP/repo-hosts"
export HOME="$TMP/home"
mkdir -p "$HOME/.ssh"
ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N "" -C "muse-web-profile-test" >/dev/null 2>&1
export MUSE_BRIDGE_STATE="$STATE"
export MUSE_BRIDGE_REPO_HOSTS="$REPO_HOSTS"
bash "$REPO_DIR/scripts/bridge.sh" add-host --host plain --port 2232 >/dev/null 2>&1
bash "$REPO_DIR/scripts/bridge.sh" add-host --host alt --port 2233 --profile-dir "Profile 2" >/dev/null 2>&1
code=0
python3 - "$REPO_HOSTS" <<'PY2' || code=$?
import json, sys
root = sys.argv[1]
plain = json.load(open(root + "/plain/card.json"))
alt = json.load(open(root + "/alt/card.json"))
assert plain["web_profile_dir"] == "Default", plain
assert plain["web_cdp_port"] == 9222, plain
assert alt["web_profile_dir"] == "Profile 2", alt
assert alt["web_cdp_port"] != plain["web_cdp_port"], (plain, alt)
assert alt["web_clone_dir"] != plain["web_clone_dir"], (plain, alt)
PY2
if [ "$code" = "0" ]; then echo "  ok   - card luu profile/cdp/clone rieng"; else echo "  FAIL - card luu profile/cdp/clone rieng"; fails=$((fails + 1)); fi

echo "== 6. link bi boc qua l.meta.ai van lay duoc URL that"
# Loi that: Muse tra link duyet node Tailscale nhung web boc qua redirect
# l.meta.ai/?u=... va cat token khoi innerText -> reply mat link hoan toan.
code=0
python3 - "$REPO_DIR" <<'PY3' || code=$?
import json, sys
sys.path.insert(0, sys.argv[1] + "/bridge")
import muse_web as mw

wrapped = ("https://l.meta.ai/?u=https%3A%2F%2Flogin.tailscale.com%2Fa%2Fgc2744ef8237bd6fe"
           "&h=AUBODStZmp2WNxj")
assert mw.unwrap_link(wrapped) == "https://login.tailscale.com/a/gc2744ef8237bd6fe"
assert mw.unwrap_link("https://muse.ai/thread/x") == "https://muse.ai/thread/x"

class FakeCDP:
    def evaluate(self, js, timeout=60):
        return json.dumps([wrapped, "https://muse.ai/thread/x", wrapped])

out = mw.with_links(FakeCDP(), "mo link nay de duyet node")
assert "LINKS:" in out
assert "https://login.tailscale.com/a/gc2744ef8237bd6fe" in out
assert out.count("gc2744ef8237bd6fe") == 1, "link trung phai khu bot"
assert "l.meta.ai" not in out.split("LINKS:")[1]

class NoLinks:
    def evaluate(self, js, timeout=60):
        return "[]"

assert mw.with_links(NoLinks(), "abc") == "abc", "khong link thi giu nguyen text"
PY3
if [ "$code" = "0" ]; then echo "  ok   - unwrap l.meta.ai + LINKS trong reply"; else echo "  FAIL - unwrap l.meta.ai + LINKS trong reply"; fails=$((fails + 1)); fi

echo
if [ "$fails" = "0" ]; then echo "MUSE_WEB_PROFILE_TEST: PASS"; else echo "MUSE_WEB_PROFILE_TEST: FAIL ($fails)"; fi
exit "$fails"
