#!/bin/bash
# ==============================================================================
# watchdog_upgrade_test.sh - Kiem tra nang cap watchdog trong Hatch boot hook:
#   - moi block watchdog cu phai bi go, chi con duy nhat block v6.
#   - block v6 phai gan theo PORT (unit per-port + pgrep theo port).
#   - inject lai phai idempotent (khong nhan ban).
#   - hook PHAI ket thuc bang HATCH_HOOK_RESULT (Hatch goi "failed" neu thieu).
# ==============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INJECT="$REPO_DIR/bridge/inject_watchdog.py"
TMP="$(mktemp -d /tmp/muse-watchdog-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

HOOK="$TMP/muse-platform-boot.sh"
cat > "$HOOK" <<'EOF'
#!/bin/bash
set -euo pipefail
# [Self-healing: Auto keep SSH and G3 Reverse Tunnel alive]
mkdir -p /run/sshd /var/run/sshd
if ! pgrep -x sshd >/dev/null 2>&1; then
    /usr/sbin/sshd 2>/dev/null || true
fi
if ! pgrep -f "reverse-tunnel" >/dev/null 2>&1; then
    nohup /bin/bash /home/hatch/workspace/muse-platform-setup/tunnel/reverse-tunnel.sh >> /home/hatch/workspace/muse-platform-setup/tunnel/tunnel.log 2>&1 &
fi
# [muse-bridge watchdog v2] BEGIN
if ! pgrep -f 'ssh -N -R' >/dev/null 2>&1; then
    nohup /bin/bash /home/hatch/workspace/muse-platform-setup/tunnel/reverse-tunnel-2222.sh >> /home/hatch/workspace/muse-platform-setup/tunnel/tunnel.log >/dev/null 2>&1 &
fi
# [muse-bridge watchdog v2] END
echo "hook chay"
EOF

fails=0
check() { if [ "$2" = "0" ]; then echo "  ok   - $1"; else echo "  FAIL - $1"; fails=$((fails+1)); fi }

LOOP="/home/hatch/workspace/muse-platform-setup/tunnel/reverse-tunnel-2222.sh"
KEY="/home/hatch/workspace/muse-platform-setup/keys/muse-agent-ed25519"
PROXY="/home/hatch/workspace/muse-platform-setup/tunnel/ts-socat-proxy.sh"

python3 "$INJECT" "$HOOK" "$LOOP" "$KEY" "$PROXY" "testuser" "100.64.0.1" >/dev/null
check "inject chay khong loi" $?

grep -q "muse-bridge watchdog v6" "$HOOK"
check "co block v6" $?
grep -q "Auto keep SSH and G3 Reverse Tunnel alive" "$HOOK"
if [ $? -eq 0 ]; then echo "  FAIL - block v1 con lai"; fails=$((fails+1)); else echo "  ok   - block v1 da bi go"; fi
grep -q "muse-bridge watchdog v2] BEGIN" "$HOOK"
if [ $? -eq 0 ]; then echo "  FAIL - block v2 con lai"; fails=$((fails+1)); else echo "  ok   - block v2 da bi go"; fi
grep -q "echo \"hook chay\"" "$HOOK"
check "phan con lai cua hook duoc giu nguyen" $?
bash -n "$HOOK"
check "hook van hop le (bash -n)" $?

# --- v6: block phai giu nguyen "%" literal trong shell ------------------------
# Loi that: BLOCK duoc format bang "%" -> moi "%" literal bi an mat.
# "date +%s" -> "date +{'port': '2222'}" -> nhanh tu cai openssh-server trong
# container KHONG BAO GIO chay -> container chet sshd la treo dai den khi co
# nguoi cai tay.
grep -q 'date +%s' "$HOOK"
check "v6 giu nguyen 'date +%s' (khong bi %-format an mat)" $?
if grep -q "date +{" "$HOOK"; then
  echo "  FAIL - placeholder %-format con lot vao block"; fails=$((fails+1))
else
  echo "  ok   - khong con placeholder %-format lot vao block"
fi
if grep -q '@@' "$HOOK"; then
  echo "  FAIL - con placeholder @@ chua duoc thay"; fails=$((fails+1))
else
  echo "  ok   - moi placeholder @@ da duoc thay"
fi

# --- v6 phai gan theo port (khong dung unit generic) -------------------------
grep -q 'UNIT="muse-reverse-tunnel-2222.service"' "$HOOK"
check "v6 dung unit per-port" $?
grep -q "ssh -N -R 2222:" "$HOOK"
check "v6 pgrep theo port" $?
grep -q "muse-reverse-tunnel.service" "$HOOK"
if [ $? -eq 0 ]; then echo "  FAIL - v6 van tro toi unit generic"; fails=$((fails+1)); else echo "  ok   - v6 khong con unit generic"; fi

# --- v6: so san LOOP_VERSION phai lay GIA TRI thuan ---------------------------
# Sai: WANT="LOOP_VERSION=\"v5\"" vs HAVE="v5" -> restart lien tuc -> tunnel chop chop.
grep -q "sed 's/.*=\"//; s/\"\$//'" "$HOOK"
check "v6 so san version lay gia tri thuan" $?

# --- v6: block phai nam SAU shebang va SAU set -euo pipefail ----------------
head -1 "$HOOK" | grep -q "^#!"
check "shebang van o dong dau (block khong chen truoc shebang)" $?
shebang_line=$(grep -n "^#!" "$HOOK" | head -1 | cut -d: -f1)
setline=$(grep -n "^set -euo pipefail" "$HOOK" | head -1 | cut -d: -f1)
blockline=$(grep -n "muse-bridge watchdog v6] BEGIN" "$HOOK" | head -1 | cut -d: -f1)
if [ -n "$shebang_line" ] && [ -n "$blockline" ] && [ "$blockline" -gt "$shebang_line" ]; then
  check "block v6 nam sau shebang" 0
else
  check "block v6 nam sau shebang" 1
fi
if [ -n "$setline" ] && [ -n "$blockline" ] && [ "$blockline" -gt "$setline" ]; then
  check "block v6 nam sau set -euo pipefail" 0
else
  check "block v6 nam sau set -euo pipefail" 1
fi

# --- v6: chi MOT supervisor (khong spawn loop khi da co systemd unit) ---------
grep -q 'if \[ "$HAVE_SYSTEMD" != "1" \] || \[ ! -f "/etc/systemd/system/$UNIT" \]; then' "$HOOK"
check "v6 khong spawn loop khi co systemd unit" $?

# --- inject lai phai idempotent ----------------------------------------------
cp "$HOOK" "$TMP/hook.after1"
python3 "$INJECT" "$HOOK" "$LOOP" "$KEY" "$PROXY" "testuser" "100.64.0.1" >/dev/null
diff -q "$TMP/hook.after1" "$HOOK" >/dev/null
check "inject lai khong doi file (idempotent)" $?

n=$(grep -c "muse-bridge watchdog v6] BEGIN" "$HOOK")
if [ "$n" = "1" ]; then
  check "chi co 1 block v6" 0
else
  check "chi co 1 block v6" 1
fi

# --- v5: so san LOOP_VERSION phai DUNG (khong restart lien tuc) --------------
# Loi goc: WANT="LOOP_VERSION=\"v5\"" != HAVE="v5" -> watchdog kill tunnel MOI 15s
# -> tunnel chop chop -> may ngoai khong bao gio SSH duoc vao container.
VDIR="$TMP/vtunnel"
mkdir -p "$VDIR"
cat > "$VDIR/reverse-tunnel-2222.sh" <<'EOF'
#!/bin/bash
LOOP_VERSION="v5"
EOF
cat > "$TMP/hook.v" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
EOF
python3 "$INJECT" "$TMP/hook.v" "$VDIR/reverse-tunnel-2222.sh" "$KEY" "$PROXY" "testuser" "100.64.0.1" >/dev/null
v_want=$(grep -E '^WANT=' "$TMP/hook.v")
v_have=$(grep -E '^HAVE=' "$TMP/hook.v")
printf 'v5\n' > "$VDIR/.loop_version"
eval "$v_want"
eval "$v_have"
if [ "$WANT" = "v5" ] && [ "$HAVE" = "v5" ]; then ver_rc=0; else ver_rc=1; fi
check "version da khop -> WANT==HAVE (khong restart lien tuc)" "$ver_rc"
printf 'v4\n' > "$VDIR/.loop_version"
eval "$v_have"
if [ "$WANT" != "$HAVE" ]; then ver_rc=0; else ver_rc=1; fi
check "version cu -> WANT!=HAVE (co restart)" "$ver_rc"

# --- v6: block cu chen TRUOC shebang phai duoc go -----------------------------
# Loi that tren host "muse": file hook bat dau bang block v4, shebang bi dan
# vao cung dong voi "END" -> hook mat shebang -> Hatch khong chay duoc script.
HOOK_V4="$TMP/hook.v4"
cat > "$HOOK_V4" <<'EOF'

# [muse-bridge watchdog v4] BEGIN
mkdir -p /run/sshd /var/run/sshd
# [muse-bridge watchdog v4] END#!/usr/bin/env bash
# muse-platform-boot.sh - boot/self-heal hook (muse-bridge)
set -euo pipefail
EOF
python3 "$INJECT" "$HOOK_V4" "$LOOP" "$KEY" "$PROXY" "testuser" "100.64.0.1" >/dev/null
head -1 "$HOOK_V4" | grep -q "^#!"
check "shebang duoc trai ve dong dau (block cu bi go)" $?
grep -q "watchdog v4] BEGIN" "$HOOK_V4"
if [ $? -eq 0 ]; then echo "  FAIL - block v4 con lai"; fails=$((fails+1)); else echo "  ok   - block v4 da bi go"; fi
bash -n "$HOOK_V4"
check "hook v4 cu lam lai van hop le (bash -n)" $?

# --- v6: hook PHAI ket thuc bang HATCH_HOOK_RESULT ---------------------------
# Loi that tren host "muse2": hook chi co block watchdog, khong define ham
# `silent` -> Hatch bao loi "script exited without calling silent() or wake()"
# -> hook FAIL -> watchdog vo hieu (unit/authorized_keys khong duoc cai lai).
STUB="$TMP/stub"; mkdir -p "$STUB"
for c in pkill pgrep systemctl nohup; do
  printf '#!/bin/sh\nexit 0\n' > "$STUB/$c"; chmod +x "$STUB/$c"
done
# timeout: gia lap banner SSH -> hook KHONG tu chay /usr/sbin/sshd that
printf '#!/bin/sh\necho SSH-2.0-STUB\nexit 0\n' > "$STUB/timeout"; chmod +x "$STUB/timeout"
HOOK_MIN="$TMP/hook.min"
printf '#!/usr/bin/env bash\nset -euo pipefail\n' > "$HOOK_MIN"
python3 "$INJECT" "$HOOK_MIN" "$LOOP" "$KEY" "$PROXY" "testuser" "100.64.0.1" >/dev/null
hook_out="$(PATH="$STUB:$PATH" bash "$HOOK_MIN" 2>&1)"; hook_rc=$?
if [ "$hook_rc" = "0" ]; then rc_res=0; else rc_res=1; fi
check "hook chay xong, exit 0" "$rc_res"
printf '%s' "$hook_out" | grep -q "HATCH_HOOK_RESULT"
check "hook in ra HATCH_HOOK_RESULT (Hatch khong bao loi)" $?

# hook co runtime that (silent co san) -> van phai ket thuc bang marker
HOOK_RT="$TMP/hook.rt"
printf '#!/usr/bin/env bash\nset -euo pipefail\nsilent() { printf "HATCH_HOOK_RESULT:%%s\\n" "$*"; exit 0; }\n' > "$HOOK_RT"
python3 "$INJECT" "$HOOK_RT" "$LOOP" "$KEY" "$PROXY" "testuser" "100.64.0.1" >/dev/null
rt_out="$(PATH="$STUB:$PATH" bash "$HOOK_RT" 2>&1)"; rt_rc=$?
if [ "$rt_rc" = "0" ]; then rc_res=0; else rc_res=1; fi
check "hook co silent that: exit 0" "$rc_res"
printf '%s' "$rt_out" | grep -q "HATCH_HOOK_RESULT"
check "hook co silent that: in ra marker" $?

# --- v6: dong "silent ..." SOT LAI NGOAI block phai duoc go ------------------
# Loi that tren host "muse2": file hook con mot dong
#   silent "muse-bridge watchdog ok"
# ngoai block (do lan inject cu de lai). `set -eu` lam script CHET ngay tai do
# -> hook FAIL, watchdog vo hieu. Inject lai phai lam sach dong sot do.
HOOK_LEFT="$TMP/hook.left"
cat > "$HOOK_LEFT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# [muse-bridge watchdog v5] BEGIN
set -eu
silent "muse-bridge watchdog ok"
# [muse-bridge watchdog v5] END
EOF
python3 "$INJECT" "$HOOK_LEFT" "$LOOP" "$KEY" "$PROXY" "testuser" "100.64.0.1" >/dev/null
if grep -q '^silent "muse-bridge watchdog ok"' "$HOOK_LEFT"; then
  echo "  FAIL - dong silent sot con lai"; fails=$((fails+1))
else
  echo "  ok   - dong silent sot da bi go"
fi
left_out="$(PATH="$STUB:$PATH" bash "$HOOK_LEFT" 2>&1)"; left_rc=$?
if [ "$left_rc" = "0" ]; then rc_res=0; else rc_res=1; fi
check "hook co dong silent sot: chay xong exit 0" "$rc_res"
printf '%s' "$left_out" | grep -q "HATCH_HOOK_RESULT"
check "hook co dong silent sot: in ra marker" $?

echo
if [ "$fails" = "0" ]; then echo "WATCHDOG_TEST: PASS"; else echo "WATCHDOG_TEST: FAIL ($fails)"; fi
exit "$fails"
