#!/bin/bash
# ==============================================================================
# host_card_test.sh - Kiem tra card host: luu thread (cho lop 4 auto-repair) va
# khong lam mat cac truong khac khi cap nhat.
#
# Van de goc: `onboard` khong luu THREAD_URL vao card -> host moi khong bao gio
# duoc danh thuc qua web (lop 4 tu phuc hoi).
#
# Hermetic: chi dung thu muc tam.
# ==============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/muse-card-test.XXXXXX)"
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

CARD="$TMP/muse3.json"
cat > "$CARD" <<'EOF'
{
  "id": "muse3",
  "label": "Muse test",
  "tunnel_port": 2224,
  "web_profile_dir": "Profile 2",
  "web_cdp_port": 9230,
  "state": "registered"
}
EOF

echo "== 1. cap nhat trang thai giu nguyen cac truong khac"
python3 "$REPO_DIR/scripts/update_host_state.py" "$CARD" 2224 >/dev/null
code=0
python3 - "$CARD" <<'PY' || code=$?
import json, sys
c = json.load(open(sys.argv[1]))
assert c["id"] == "muse3", c
assert c["web_profile_dir"] == "Profile 2", c
assert c["web_cdp_port"] == 9230, c
assert "thread" not in c, "khong duoc them thread khi khong truyen --thread"
assert c["state"] in ("connected", "waiting"), c
PY
if [ "$code" = "0" ]; then echo "  ok   - giu nguyen id/web_profile/web_cdp, khong them thread"; else echo "  FAIL - giu nguyen id/web_profile/web_cdp"; fails=$((fails + 1)); fi

echo "== 2. --thread luu vao card"
python3 "$REPO_DIR/scripts/update_host_state.py" "$CARD" 2224 --thread "https://muse.ai/thread/abc-123" >/dev/null
code=0
python3 - "$CARD" <<'PY2' || code=$?
import json, sys
c = json.load(open(sys.argv[1]))
assert c.get("thread") == "https://muse.ai/thread/abc-123", c
PY2
if [ "$code" = "0" ]; then echo "  ok   - thread duoc luu vao card"; else echo "  FAIL - thread duoc luu vao card"; fails=$((fails + 1)); fi

echo "== 3. --thread khong lam mat gi khi cap nhat lai khong co --thread"
python3 "$REPO_DIR/scripts/update_host_state.py" "$CARD" 2224 >/dev/null
code=0
python3 - "$CARD" <<'PY3' || code=$?
import json, sys
c = json.load(open(sys.argv[1]))
assert c.get("thread") == "https://muse.ai/thread/abc-123", c
PY3
if [ "$code" = "0" ]; then echo "  ok   - thread duoc giu nguyen"; else echo "  FAIL - thread duoc giu nguyen"; fails=$((fails + 1)); fi

echo "== 4. usage sai -> exit != 0"
python3 "$REPO_DIR/scripts/update_host_state.py" "$CARD" >/dev/null 2>&1
if [ $? -ne 0 ]; then res=0; else res=1; fi
if [ "$res" = "0" ]; then echo "  ok   - thieu tham so -> exit khac 0"; else echo "  FAIL - thieu tham so -> exit khac 0"; fails=$((fails + 1)); fi

echo "== 5. onboard luu chat rieng vao card"
ok "local_side.sh luu thread bang save_bridge_thread" \
  grep -q 'save_bridge_thread "\$thread"' "$REPO_DIR/bridge/local_side.sh"

echo "== 6. repair KHONG doan thread tu History (doan sai -> tin roi vao chat nguoi dung)"
ok "khong con ham find_thread_web" \
  bash -c "! grep -q 'find_thread_web' '$REPO_DIR/bridge/local_side.sh'"
ok "driver khong con quet History de doan thread" \
  bash -c "! grep -q 'candidate_threads' '$REPO_DIR/bridge/muse_web.py'"
ok "repair lay thread da luu trong card" \
  grep -q 'thread="\$(host_bridge_thread)"' "$REPO_DIR/bridge/local_side.sh"

echo "== 7. doctor/hosts cap nhat card TRUOC khi doc state"
code=0
python3 - "$REPO_DIR/bridge/local_side.sh" <<'PY7' || code=$?
import re, sys
src = open(sys.argv[1]).read()
# Tim khoi block doctor/hosts: cap nhat card phai xuat hien TRUOC lenh doc state.
bad = []
for fn in ("cmd_hosts", "cmd_doctor"):
    m = re.search(r"^%s\(\) \{\n(.*?)^\}" % fn, src, re.S | re.M)
    if not m:
        bad.append("%s: khong tim thay ham" % fn)
        continue
    body = m.group(1)
    up = body.find("update_host_state.py")
    rd = body.find('card_field "$id" "state"')
    if up < 0:
        bad.append("%s: khong goi update_host_state.py" % fn)
    elif rd < 0:
        bad.append("%s: khong doc state" % fn)
    elif up > rd:
        bad.append("%s: doc state TRUOC khi cap nhat card -> in gia tri cu" % fn)
if bad:
    print("\n".join(bad))
    sys.exit(1)
PY7
if [ "$code" = "0" ]; then echo "  ok   - cap nhat card truoc khi doc state"; else echo "  FAIL - cap nhat card truoc khi doc state"; fails=$((fails + 1)); fi

echo
if [ "$fails" = "0" ]; then echo "HOST_CARD_TEST: PASS"; else echo "HOST_CARD_TEST: FAIL ($fails)"; fi
exit "$fails"
