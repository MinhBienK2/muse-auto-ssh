#!/bin/bash
# ==============================================================================
# forward_release_test.sh - Kiem tra co "dung session treo" cua lop giu phien SSH.
#
#   bash tests/forward_release_test.sh
#
# Loi that da bi chung minh:
#   1) `pkill -o -u <user> -f "^sshd: <user>$"` KHONG BAO GIO match (cmdline that
#      cua sshd co NUL duoi -> regex co `$` khong khop) -> no-op vinh vien.
#   2) Neu bo `$` thi `pkill -o` lai chon session GIA NHAT -> co the giet nham
#      session cua host KHAC dang khoe (port 2223 khoe nhung session 2222 treo).
#
# Co che dung: khoanh vung theo scope cua CHINH listener socket cua port do
# (ss -tlnpe -> cgroup -> session-N.scope) -> dung session, dung host.
#
# Test hermetic: /proc va `ss` deu la gia lap (MUSE_PROC_ROOT + stub PATH).
# ==============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/muse-fwd-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fails=0
check() { if [ "$2" = "0" ]; then echo "  ok   - $1"; else echo "  FAIL - $1"; fails=$((fails+1)); fi }

# --- /proc gia lap ------------------------------------------------------------
# 1111: sshd user-owned trong session-A (port 2222)  -> phai bi dung
# 2222: sshd [priv] trong session-A                 -> root, khong kill duoc
# 3333: sshd user-owned trong session-B (port 2223)  -> KHONG duoc dung
# 4444: sshd user-owned trong session-A nhung cmdline khong phai "sshd: ..." -> bo qua
PROC="$TMP/proc"
mk_proc_pid() {
  local pid="$1" scope="$2" cmd="$3"
  mkdir -p "$PROC/$pid"
  printf '0::/user.slice/user-1000.slice/%s\n' "$scope" > "$PROC/$pid/cgroup"
  printf '%s\0' "$cmd" > "$PROC/$pid/cmdline"
}
mk_proc_pid 1111 "session-1011.scope" "sshd: tester"
mk_proc_pid 2222 "session-1011.scope" "sshd: tester [priv]"
mk_proc_pid 3333 "session-1012.scope" "sshd: tester"
mk_proc_pid 4444 "session-1011.scope" "some-other-daemon"

# --- ss stub: tra ve listener cho port 2222 (session-A) va 2223 (session-B) ----
# `ss -tlnpe` khong nhan port qua argv -> stub phai in TAT CA listener.
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/ss" <<EOF
#!/bin/bash
echo "LISTEN 0 128 127.0.0.1:2222 0.0.0.0:* uid:1000 ino:1 sk:2 cgroup:/user.slice/user-1000.slice/session-1011.scope"
echo "LISTEN 0 128 127.0.0.1:2223 0.0.0.0:* uid:1000 ino:3 sk:4 cgroup:/user.slice/user-1000.slice/session-1012.scope"
exit 0
EOF
chmod +x "$STUB/ss"

# --- nap cac ham tu local_side.sh (khong chay phan dispatch) ------------------
# local_side.sh chay lenh theo \$1; goi voi lenh rong -> usage + exit 2.
# Ta chi lay phan Dinh NGHIA HAM: cat file, bo phan dispatch, roi source.
FUNCS="$TMP/funcs.sh"
sed '/^# ------------------------------------------------------------------ dispatch/,$d' "$REPO_DIR/bridge/local_side.sh" > "$FUNCS"

export MUSE_PROC_ROOT="$PROC"
export MUSE_BRIDGE_STATE="$TMP/state"
export PATH="$STUB:$PATH"

# shellcheck source=/dev/null
. "$FUNCS"

# --- 1) forward_scope phai lay scope DUNG cua listener ------------------------
scope_a="$(forward_scope 2222)"
[ "$scope_a" = "session-1011.scope" ] && res=0 || res=1
check "forward_scope 2222 tra ve scope cua listener 2222" "$res"

scope_b="$(forward_scope 2223)"
[ "$scope_b" = "session-1012.scope" ] && res=0 || res=1
check "forward_scope 2223 tra ve scope cua listener 2223" "$res"

forward_scope 9999 >/dev/null 2>&1 && res=1 || res=0
check "forward_scope tren port khong co listener -> that (khong loi)" "$res"

# --- 2) forward_scope_pids phai CHI lay pid trong dung scope ------------------
pids_a="$(forward_scope_pids session-1011.scope | tr '\n' ' ')"
case "$pids_a" in
  *1111*) res=0 ;; *) res=1 ;;
esac
check "scope A chua pid 1111 (sshd user-owned)" "$res"
case "$pids_a" in
  *3333*) res=1 ;; *) res=0 ;;
esac
check "scope A KHONG chua pid 3333 (thuoc session B)" "$res"

# --- 3) forward_release phai dung DUNG pid, khong dung pid cua host khac ------
# Ghi lai cac pid bi kill thay vi kill that (stub ham kill).
KILLED="$TMP/killed"
cat > "$STUB/kill" <<EOF
#!/bin/bash
echo "\$1" >> "$KILLED"
exit 0
EOF
chmod +x "$STUB/kill"

# forward_release goi lenh "kill" (builtin) -> can override bang ham shell.
kill() { echo "$1" >> "$KILLED"; return 0; }

forward_release 2222 >/dev/null 2>&1
res=0
grep -qx 1111 "$KILLED" 2>/dev/null || res=1
check "forward_release 2222 dung pid 1111 (sshd giu port 2222)" "$res"

res=0
grep -qx 3333 "$KILLED" 2>/dev/null && res=1
check "forward_release 2222 KHONG dung pid 3333 (session host khac)" "$res"

res=0
grep -qx 4444 "$KILLED" 2>/dev/null && res=1
check "forward_release 2222 KHONG dung pid 4444 (khong phai sshd)" "$res"

# --- 4) release tren port khong co listener -> that ---------------------------
: > "$KILLED"
forward_release 9999 >/dev/null 2>&1 && res=1 || res=0
check "forward_release tren port khong co listener -> that" "$res"
[ ! -s "$KILLED" ] && res=0 || res=1
check "forward_release that -> khong dung gi ca" "$res"

# --- 5) regex cu cua pkill co that trong code khong (chong tai phat) ---------
if grep -n 'pkill .*sshd: .*\$' "$REPO_DIR/bridge/local_side.sh" >/dev/null 2>&1; then
  res=1
else
  res=0
fi
check "local_side.sh khong con pkill theo regex 'sshd: <user>\$'" "$res"

echo
if [ "$fails" = "0" ]; then echo "FORWARD_TEST: PASS"; else echo "FORWARD_TEST: FAIL ($fails)"; fi
exit "$fails"
