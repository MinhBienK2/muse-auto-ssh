#!/bin/bash
# ==============================================================================
# chrome_profiles_test.sh - Kiem tra helper liet ke Chrome profile ( dung de
# skill /setup-ssh-muse hoi user chon profile Chrome nao).
#
#   1. Doc ten/tri/email tu Local State + Preferences.
#   2. Phan biet cookie muse.ai CON SONG (dang nhap) vs het han.
#   3. Dem URL muse.ai trong History.
#   4. Biet host nao dang dung profile nao (used_by).
#   5. --only-muse / --text hoat dong.
#   6. bridge.sh profiles --json tra ve JSON hop le.
#   7. Skill hoi bang danh sach THAT, khong hard-code Default/Profile 2.
#
# Hermetic: dung thu muc Chrome gia + card host gia -> khong doc trang thai that.
# ==============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/muse-chrome-profiles-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

FAKE="$TMP/chrome"
HOSTS="$TMP/hosts"
mkdir -p "$FAKE" "$HOSTS"

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

rc() {
  if [ "$2" = "0" ]; then
    echo "  ok   - $1"
  else
    echo "  FAIL - $1"
    fails=$((fails + 1))
  fi
}

# ------------------------------------------------------------------ du lieu gia
code=0
python3 - "$FAKE" "$HOSTS" <<'PY' || code=$?
import json, os, sqlite3, sys, time

src, hosts = sys.argv[1], sys.argv[2]
now = (time.time() + 11644473600) * 1_000_000
alive = now + 10_000_000_000_000
dead = now - 10_000_000_000_000

json.dump(
    {"profile": {"info_cache": {
        "Default": {"name": "A One", "user_name": "a@example.invalid"},
        "Profile 2": {"name": "B Two", "user_name": "b@example.invalid"},
        "Profile 3": {"name": "C Three"},
    }}},
    open(os.path.join(src, "Local State"), "w"),
)


def mk(name):
    d = os.path.join(src, name)
    os.makedirs(d, exist_ok=True)
    return d


def cookies(name, rows):
    d = mk(name)
    con = sqlite3.connect(os.path.join(d, "Cookies"))
    con.execute("create table cookies (host_key text, name text, expires_utc integer)")
    con.executemany("insert into cookies values (?,?,?)", rows)
    con.commit()
    con.close()


def history(name, urls):
    d = mk(name)
    con = sqlite3.connect(os.path.join(d, "History"))
    con.execute("create table urls (url text)")
    con.executemany("insert into urls values (?)", [(u,) for u in urls])
    con.commit()
    con.close()


# Default: dang nhap Muse (cookie song) + 2 trang muse.ai + 2 account trong profile
cookies("Default", [(".muse.ai", "hatch_sess", alive), ("muse.ai", "theme", alive),
                    (".muse.ai", "old", dead), ("example.com", "x", alive)])
history("Default", ["https://muse.ai/thread/a", "https://muse.ai/thread/b",
                    "https://example.com/x"])
json.dump({"account_info": [{"email": "a@example.invalid"}, {"email": "a2@example.invalid"}]},
          open(os.path.join(mk("Default"), "Preferences"), "w"))

# Profile 2: co lich su muse.ai nhung cookie da het han -> da logout
cookies("Profile 2", [(".muse.ai", "hatch_sess", dead)])
history("Profile 2", ["https://muse.ai/thread/c"])

# Profile 3: khong he dung muse.ai
mk("Profile 3")

# Card host gia: muse -> mac dinh Default, muse3 -> Profile 2, muse4 -> Profile 3
for hid, profile in (("muse", None), ("muse3", "Profile 2"), ("muse4", "Profile 3")):
    card = {"id": hid}
    if profile:
        card["web_profile_dir"] = profile
    json.dump(card, open(os.path.join(hosts, hid + ".json"), "w"))
PY
rc "tao du lieu Chrome gia" "$code"

OUT="$TMP/out.json"

echo "== 1. doc Local State + Preferences + cookie + History"
code=0
python3 "$REPO_DIR/scripts/chrome_profiles.py" --profile-src "$FAKE" --hosts-dir "$HOSTS" \
  --json > "$OUT" || code=$?
rc "helper chay duoc" "$code"
ok "helper sinh JSON" python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$OUT"

code=0
python3 - "$OUT" <<'PY' || code=$?
import json, sys

recs = {r["profile_dir"]: r for r in json.load(open(sys.argv[1], encoding="utf-8"))}
errs = []


def check(cond, msg):
    if not cond:
        errs.append(msg)


check(set(recs) == {"Default", "Profile 2", "Profile 3"}, "profile dirs: %s" % sorted(recs))

d = recs["Default"]
check(d["display_name"] == "A One", "display_name: %r" % d["display_name"])
check(d["email"] == "a@example.invalid", "email: %r" % d["email"])
check(d["emails"] == ["a@example.invalid", "a2@example.invalid"], "emails: %r" % d["emails"])
check(d["muse_urls"] == 2, "muse_urls: %r" % d["muse_urls"])
check(d["muse_session"] == 2, "muse_session: %r" % d["muse_session"])
check(d["logged_in"] is True, "logged_in: %r" % d["logged_in"])
check(d["used_by"] == ["muse"], "used_by: %r" % d["used_by"])

p2 = recs["Profile 2"]
check(p2["logged_in"] is False, "Profile 2 logged_in: %r" % p2["logged_in"])
check(p2["has_muse"] is True, "Profile 2 has_muse: %r" % p2["has_muse"])
check(p2["muse_urls"] == 1, "Profile 2 muse_urls: %r" % p2["muse_urls"])
check(p2["used_by"] == ["muse3"], "Profile 2 used_by: %r" % p2["used_by"])

p3 = recs["Profile 3"]
check(p3["has_muse"] is False, "Profile 3 has_muse: %r" % p3["has_muse"])
check(p3["used_by"] == ["muse4"], "Profile 3 used_by: %r" % p3["used_by"])

if errs:
    print("\n".join("    - " + e for e in errs))
    sys.exit(1)
PY
rc "noi dung JSON dung nhu mong doi" "$code"

echo "== 2. --only-muse va --text"
code=0
n="$(python3 "$REPO_DIR/scripts/chrome_profiles.py" --profile-src "$FAKE" --hosts-dir "$HOSTS" \
  --only-muse --json | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")" || code=$?
rc "chay --only-muse" "$code"
ok "chi giu 2 profile co muse.ai" test "$n" = "2"

code=0
python3 "$REPO_DIR/scripts/chrome_profiles.py" --profile-src "$FAKE" --hosts-dir "$HOSTS" \
  --text > "$TMP/out.txt" || code=$?
rc "chay --text" "$code"
ok "bang co tieu de" grep -q "PROFILE_DIR" "$TMP/out.txt"
ok "bang co email" grep -q "a@example.invalid" "$TMP/out.txt"
ok "bang co profile khong dung" grep -q "Profile 3" "$TMP/out.txt"

echo "== 3. khong co Chrome -> khong loi"
code=0
out="$(python3 "$REPO_DIR/scripts/chrome_profiles.py" --profile-src "$TMP/does-not-exist" --json)" || code=$?
rc "khong lo khi thu muc khong ton tai" "$code"
ok "tra ve JSON rong" bash -c '[[ "$1" == "[]" ]]' _ "$out"

echo "== 4. bridge.sh profiles"
code=0
bash "$REPO_DIR/scripts/bridge.sh" profiles --json > "$TMP/cli.json" || code=$?
rc "bridge.sh profiles --json chay duoc" "$code"
ok "CLI tra ve JSON hop le" python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$TMP/cli.json"
code=0
bash "$REPO_DIR/scripts/bridge.sh" profiles >/dev/null || code=$?
rc "bridge.sh profiles (bang chu) chay duoc" "$code"

echo "== 5. skill hoi bang danh sach that"
SKILL="$REPO_DIR/.agents/setup-ssh-muse/SKILL.md"
ok "skill goi lenh profiles" grep -q "scripts/bridge.sh profiles" "$SKILL"
ok "skill khong hard-code Default/Profile 2" bash -c \
  '! grep -qE "Profile Chrome\*\*: .Default. \(mặc định\) hay .Profile 2." "$1"' _ "$SKILL"
ok "skill noi ro van hoi khi chi co 1 profile" grep -q "vẫn hỏi" "$SKILL"

echo
if [ "$fails" = "0" ]; then echo "CHROME_PROFILES_TEST: PASS"; else echo "CHROME_PROFILES_TEST: FAIL ($fails)"; fi
exit "$fails"
