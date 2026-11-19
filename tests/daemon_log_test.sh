#!/bin/bash
# ==============================================================================
# daemon_log_test.sh - Kiem tra log cua daemon (bridge/local_side.sh cmd_daemon).
#
# Voi sao can: vong lap poll moi 10s in "SYNC nothing-pending" + "PULL failed"
# -> log phinh to 9MB trong 2 tuan. Da sua: loc dong rong, ghep dong trung
# lap, cat log khi vuot 1MB.
#
# Hermetic: hai ham duoc tach tu file that va tro duong dan vao sandbox (TMP)
# -> khong cham file that cua nguoi dung.
# ==============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/muse-daemon-log.XXXXXX)"
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
contains() { grep -q "$2" "$1"; }
lacks()    { ! grep -q "$2" "$1"; }

log="$TMP/inbox-muse.log"
: > "$log"

# Lay 2 ham tu file that (co thut trong cmd_daemon) -> tro duong dan vao sandbox
{
  sed -n '/^  daemon_log_line()/,/^  }/p' "$REPO_DIR/bridge/local_side.sh"
  sed -n '/^  daemon_log_filter()/,/^  }/p' "$REPO_DIR/bridge/local_side.sh"
  sed -n '/^  daemon_log_cap()/,/^  }/p' "$REPO_DIR/bridge/local_side.sh"
} > "$TMP/fn.sh"
if ! grep -q "daemon_log_filter()" "$TMP/fn.sh"; then
  echo "  FAIL - khong tim thay ham daemon_log_filter trong bridge/local_side.sh"
  exit 1
fi
if ! grep -q "daemon_log_cap()" "$TMP/fn.sh"; then
  echo "  FAIL - khong tim thay ham daemon_log_cap trong bridge/local_side.sh"
  exit 1
fi
# shellcheck source=/dev/null
. "$TMP/fn.sh"
say() { :; }

# Bien trang thai do ham daemon_log_filter dung (ke qua cac vong poll).
# export de shellcheck biet bien duoc dung o ben ngoai ham tach tu file that.
DAEMON_LOG_PREV="" DAEMON_LOG_CNT=0
export DAEMON_LOG_PREV DAEMON_LOG_CNT
reset_log_state() {
  DAEMON_LOG_PREV=""; DAEMON_LOG_CNT=0
  export DAEMON_LOG_PREV DAEMON_LOG_CNT
}

echo "== 1. dong rong (nothing-pending / messages=0) bi lo"
# Luu y: goi qua here-string, KHONG pipe - pipe se chay filter o subshell ->
# bien trang thai khong song sot qua cac vong (dung chinh trong code).
daemon_log_filter <<< "SYNC nothing-pending
PULL nothing
PULL messages=0
PULL messages=2"
ok "khong con 'SYNC nothing-pending'"  lacks "$log" "nothing-pending"
ok "khong con 'PULL messages=0'"      lacks "$log" "PULL messages=0"
ok "van giu 'PULL messages=2'"       contains "$log" "PULL messages=2"

echo "== 2. dong trung lap duoc ghep lai (ke ca qua cac vong poll)"
: > "$log"
reset_log_state
# 3 vong poll, moi vong in cung 1 dong loi -> chi ghi 1 lan
for _ in 1 2 3; do
  daemon_log_filter <<< "PULL failed: ssh: connect to host 127.0.0.1 port 2222: Connection refused"
done
ok "dong loi chi xuat hien 1 lan"  bash -c '[ "$(grep -c "PULL failed" "$1")" = 1 ]' _ "$log"

echo "== 3. dong lap 20 lan moi ghi lai so lan"
: > "$log"
reset_log_state
for _ in $(seq 1 25); do
  daemon_log_filter <<< "PULL failed: connection refused"
done
ok "co dong tom tat so lan"       contains "$log" "x20 lan"

echo "== 4. doi dong -> dong cu ghi lai so lan roi dong moi ghi"
: > "$log"
reset_log_state
daemon_log_filter <<< "DONG A
DONG A
DONG B"
ok "co dong A"                    contains "$log" "DONG A"
ok "co dong B"                    contains "$log" "DONG B"

echo "== 5. log lon duoc cat con 300 dong cuoi"
head -c 2000000 /dev/zero | tr '\0' 'x' > "$log"
for i in $(seq 1 400); do echo "dong $i" >> "$log"; done
daemon_log_cap
size="$(stat -c%s "$log" 2>/dev/null || echo 0)"
ok "log da nho lai (<=1MB), hien tai ${size}B" bash -c "[ $size -le 1048576 ]"
ok "dong cuoi van con"            contains "$log" "dong 400"

echo
if [ "$fails" -eq 0 ]; then
  echo "ALL TESTS: PASS"
else
  echo "ALL TESTS: FAIL ($fails)"
fi
exit $((fails > 0))
