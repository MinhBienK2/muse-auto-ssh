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
check() { # check <label> <condition-result>
  if [ "$2" = "0" ]; then echo "  ok   - $1"; else echo "  FAIL - $1"; fails=$((fails+1)); fi
}

echo "== 1. local -> muse (HELLO)"
python3 "$BRIDGE" --config "$LOCAL_SPOOL/config.json" send \
  --type HELLO --subject "xin chao" --body "toi day" >/dev/null
n=$(ls "$MUSE_SPOOL/inbox" 2>/dev/null | grep -c '\.json$')
check "muse inbox co 1 tin" "$([ "$n" = "1" ]; echo $?)"
grep -q '"type": "HELLO"' "$MUSE_SPOOL"/inbox/*.json
check "noi dung HELLO dung" $?

echo "== 2. muse -> local (ANSWER)"
id=$(basename "$MUSE_SPOOL"/inbox/*.json .json)
python3 "$BRIDGE" --config "$MUSE_SPOOL/config.json" send \
  --type ANSWER --subject "tra loi" --body "ok roi" --reply-to "$id" >/dev/null
n=$(ls "$LOCAL_SPOOL/inbox" 2>/dev/null | grep -c '\.json$')
check "local inbox co 1 tin" "$([ "$n" = "1" ]; echo $?)"
grep -q "\"reply_to\": \"$id\"" "$LOCAL_SPOOL"/inbox/*.json
check "reply_to lien ket dung" $?

echo "== 3. doc inbox + ack"
out=$(python3 "$BRIDGE" --config "$LOCAL_SPOOL/config.json" inbox)
echo "$out" | grep -q "subject=tra loi"
check "inbox hien thi tin nhan" $?
lid=$(basename "$LOCAL_SPOOL"/inbox/*.json .json)
python3 "$BRIDGE" --config "$LOCAL_SPOOL/config.json" ack "$lid" >/dev/null 2>&1 || true
[ ! -f "$LOCAL_SPOOL/inbox/$lid.json" ]
check "ack chuyen tin ra read/" $?
[ -f "$LOCAL_SPOOL/read/$lid.json" ]
check "tin nam trong read/" $?

echo "== 4. status"
python3 "$BRIDGE" --config "$LOCAL_SPOOL/config.json" status >/dev/null
check "status chay OK" $?

echo "== 5. giu tin khi peer down (pending -> sync)"
cat > "$LOCAL_SPOOL/config.json.broken" <<EOF
{"role":"local","spool":"$LOCAL_SPOOL",
 "peer":{"role":"muse","transport":"ssh","host":"127.0.0.1","port":22222,"user":"root","spool":"$MUSE_SPOOL",
         "ssh_opts":["-o","BatchMode=yes","-o","ConnectTimeout=3"]}}
EOF
out=$(python3 "$BRIDGE" --config "$LOCAL_SPOOL/config.json.broken" send --type NOTE --subject "x" --body "y" 2>&1)
echo "$out" | grep -q "^QUEUED"
check "peer down -> QUEUED" $?
[ -f "$LOCAL_SPOOL/pending"/*.json ] 2>/dev/null
check "tin luu trong pending/" $?

echo "== 6. sync lai khi peer up"
cp "$LOCAL_SPOOL/config.json.broken" "$TMP/broken.bak"
python3 - "$LOCAL_SPOOL/config.json.broken" <<'PY'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["peer"]["transport"] = "dir"
json.dump(cfg, open(p, "w"))
PY
python3 "$BRIDGE" --config "$LOCAL_SPOOL/config.json.broken" sync >/dev/null
[ -z "$(ls "$LOCAL_SPOOL/pending"/*.json 2>/dev/null)" ]
check "pending duoc giao hang" $?

echo
if [ "$fails" = "0" ]; then
  echo "SELFTEST: PASS"
else
  echo "SELFTEST: FAIL ($fails)"
fi
exit "$fails"
