#!/bin/bash
# ==============================================================================
# watchdog_upgrade_test.sh - Kiem tra nang cap watchdog trong Hatch boot hook:
#   - moi block watchdog cu (v1/v2/v3) phai bi go, chi con duy nhat block v4.
#   - block v4 phai gan theo PORT (unit per-port + pgrep theo port).
#   - inject lai phai idempotent (khong nhan ban).
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

grep -q "muse-bridge watchdog v4" "$HOOK"
check "co block v4" $?
grep -q "Auto keep SSH and G3 Reverse Tunnel alive" "$HOOK"
if [ $? -eq 0 ]; then echo "  FAIL - block v1 con lai"; fails=$((fails+1)); else echo "  ok   - block v1 da bi go"; fi
grep -q "muse-bridge watchdog v2] BEGIN" "$HOOK"
if [ $? -eq 0 ]; then echo "  FAIL - block v2 con lai"; fails=$((fails+1)); else echo "  ok   - block v2 da bi go"; fi
grep -q "echo \"hook chay\"" "$HOOK"
check "phan con lai cua hook duoc giu nguyen" $?
bash -n "$HOOK"
check "hook van hop le (bash -n)" $?

# --- v4 phai gan theo port (khong dung unit generic) -------------------------
grep -q 'UNIT="muse-reverse-tunnel-2222.service"' "$HOOK"
check "v4 dung unit per-port" $?
grep -q "ssh -N -R 2222:" "$HOOK"
check "v4 pgrep theo port" $?
grep -q "muse-reverse-tunnel.service" "$HOOK"
if [ $? -eq 0 ]; then echo "  FAIL - v4 van tro toi unit generic"; fails=$((fails+1)); else echo "  ok   - v4 khong con unit generic"; fi

# --- inject lai phai idempotent ----------------------------------------------
cp "$HOOK" "$TMP/hook.after1"
python3 "$INJECT" "$HOOK" "$LOOP" "$KEY" "$PROXY" "testuser" "100.64.0.1" >/dev/null
diff -q "$TMP/hook.after1" "$HOOK" >/dev/null
check "inject lai khong doi file (idempotent)" $?

n=$(grep -c "muse-bridge watchdog v4] BEGIN" "$HOOK")
[ "$n" = "1" ]
check "chi co 1 block v4" $?

echo
if [ "$fails" = "0" ]; then echo "WATCHDOG_TEST: PASS"; else echo "WATCHDOG_TEST: FAIL ($fails)"; fi
exit "$fails"
