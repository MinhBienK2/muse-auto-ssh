#!/bin/bash
# ==============================================================================
# bus_selftest.sh - Kiem tra bus hai huong tren dia phuong (khong can mang).
#
# Dung hai instance bridge.py voi transport "dir" (spool chung dia phuong) de
# kiem tra: gui/nhan, ack, status, va handoff tin nhan.
# ==============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE="$REPO_DIR/bridge/bridge.py"
TMP="$(mktemp -d /tmp/muse-bus-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

LOCAL_SPOOL="$TMP/local"
MUSE_SPOOL="$TMP/muse"
mkdir -p "$LOCAL_SPOOL" "$MUSE_SPOOL"

cat > "$LOCAL_SPOOL/config.json" <<EOF
{"role":"local","spool":"$LOCAL_SPOOL",
 "peer":{"role":"muse","transport":"dir","host":"127.0.0.1","port":2222,"user":"root","spool":"$MUSE_SPOOL"}}
EOF
cat > "$MUSE_SPOOL/config.json" <<EOF
{"role":"muse","spool":"$MUSE_SPOOL",
 "peer":{"role":"local","transport":"dir","host":"127.0.0.1","port":2222,"user":"root","spool":"$LOCAL_SPOOL"}}
EOF

fails=0

# check <label> <command...>  -- command exit 0 = PASS
check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  ok   - $label"
  else
    echo "  FAIL - $label"
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

# has_json <dir> -- co it nhat 1 file .json
has_json() {
  local dir="$1" f
  for f in "$dir"/*.json; do
    [ -f "$f" ] && return 0
  done
  return 1
}

echo "== 1. local -> muse (HELLO)"
python3 "$BRIDGE" --config "$LOCAL_SPOOL/config.json" send \
  --type HELLO --subject "xin chao" --body "toi day" >/dev/null
check "muse inbox co 1 tin" test "$(count_json "$MUSE_SPOOL/inbox")" = "1"
check "noi dung HELLO dung" grep -q '"type": "HELLO"' "$MUSE_SPOOL"/inbox/*.json

echo "== 2. muse -> local (ANSWER)"
id=$(basename "$MUSE_SPOOL"/inbox/*.json .json)
python3 "$BRIDGE" --config "$MUSE_SPOOL/config.json" send \
  --type ANSWER --subject "tra loi" --body "ok roi" --reply-to "$id" >/dev/null
check "local inbox co 1 tin" test "$(count_json "$LOCAL_SPOOL/inbox")" = "1"
check "reply_to lien ket dung" grep -q "\"reply_to\": \"$id\"" "$LOCAL_SPOOL"/inbox/*.json

echo "== 3. doc inbox + ack"
out=$(python3 "$BRIDGE" --config "$LOCAL_SPOOL/config.json" inbox)
echo "$out" | grep -q "subject=tra loi"
check "inbox hien thi tin nhan" grep -q "subject=tra loi" <<<"$out"
lid=$(basename "$LOCAL_SPOOL"/inbox/*.json .json)
python3 "$BRIDGE" --config "$LOCAL_SPOOL/config.json" ack "$lid" >/dev/null 2>&1 || true
check "ack chuyen tin ra read/" test ! -f "$LOCAL_SPOOL/inbox/$lid.json"
check "tin nam trong read/" test -f "$LOCAL_SPOOL/read/$lid.json"

echo "== 4. status"
check "status chay OK" python3 "$BRIDGE" --config "$LOCAL_SPOOL/config.json" status

echo "== 5. giu tin khi peer down (pending -> sync)"
cat > "$LOCAL_SPOOL/config.json.broken" <<EOF
{"role":"local","spool":"$LOCAL_SPOOL",
 "peer":{"role":"muse","transport":"ssh","host":"127.0.0.1","port":22222,"user":"root","spool":"$MUSE_SPOOL",
         "ssh_opts":["-o","BatchMode=yes","-o","ConnectTimeout=3"]}}
EOF
out=$(python3 "$BRIDGE" --config "$LOCAL_SPOOL/config.json.broken" send --type NOTE --subject "x" --body "y" 2>&1)
check "peer down -> QUEUED" grep -q "^QUEUED" <<<"$out"
check "tin luu trong pending/" has_json "$LOCAL_SPOOL/pending"

echo "== 5b. pull: keo tin pending cua peer ve inbox cua toi"
cp "$LOCAL_SPOOL/config.json" "$TMP/local-pull.json"
python3 - "$LOCAL_SPOOL/config.json" "$TMP/local-pull.json" <<'PY2'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg["peer"]["transport"] = "dir"
json.dump(cfg, open(sys.argv[2], "w"))
PY2
# peer (muse) co mot tin chua gui duoc -> nam trong pending/
mkdir -p "$MUSE_SPOOL/pending"
cat > "$MUSE_SPOOL/pending/20260101T000000Z-testpull.json" <<'PY3'
{"v":1,"id":"20260101T000000Z-testpull","ts":"2026-01-01T00:00:00Z","from":"muse","to":"local","host":"muse","type":"NOTE","subject":"pulled","body":"x","reply_to":null,"meta":{}}
PY3
out=$(python3 "$BRIDGE" --config "$TMP/local-pull.json" pull)
check "pull lay 1 tin tu peer" grep -q "messages=1" <<<"$out"
check "tin da ve inbox cua toi" test -f "$LOCAL_SPOOL/inbox/20260101T000000Z-testpull.json"
check "tin bi xoa o peer (khong keo trung)" test ! -f "$MUSE_SPOOL/pending/20260101T000000Z-testpull.json"
out=$(python3 "$BRIDGE" --config "$TMP/local-pull.json" pull)
check "pull lan 2 khong trung tin" grep -q "messages=0" <<<"$out"

echo "== 6. sync lai khi peer up"
cp "$LOCAL_SPOOL/config.json.broken" "$TMP/broken.bak"
python3 - "$LOCAL_SPOOL/config.json.broken" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg["peer"]["transport"] = "dir"
json.dump(cfg, open(sys.argv[1], "w"))
PY
python3 "$BRIDGE" --config "$LOCAL_SPOOL/config.json.broken" sync >/dev/null
check "pending duoc giao hang" bash -c '! ls "$1"/pending/*.json >/dev/null 2>&1' _ "$LOCAL_SPOOL"

echo
if [ "$fails" = "0" ]; then
  echo "BUS_SELFTEST: PASS"
else
  echo "BUS_SELFTEST: FAIL ($fails)"
fi
exit "$fails"
