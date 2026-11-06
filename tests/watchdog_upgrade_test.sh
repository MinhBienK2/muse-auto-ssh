#!/bin/bash
# ==============================================================================
# watchdog_upgrade_test.sh - Kiem tra nang cap watchdog trong Hatch boot hook:
#   - block v1 (chi pgrep) phai bi go va thay bang v2 (kiem tra chuc nang).
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
echo "hook chay"
EOF

fails=0
check() { if [ "$2" = "0" ]; then echo "  ok   - $1"; else echo "  FAIL - $1"; fails=$((fails+1)); fi }

python3 "$INJECT" "$HOOK" "/home/hatch/workspace/muse-platform-setup/tunnel/reverse-tunnel.sh" \
  "/home/hatch/workspace/muse-platform-setup/keys/muse-agent-ed25519" \
  "/home/hatch/workspace/muse-platform-setup/tunnel/ts-socat-proxy.sh" \
  "testuser" "100.64.0.1" >/dev/null
check "inject chay khong loi" $?

grep -q "muse-bridge watchdog v3" "$HOOK"
check "co block v2" $?
grep -q "Auto keep SSH and G3 Reverse Tunnel alive" "$HOOK"
if [ $? -eq 0 ]; then echo "  FAIL - block v1 con lai"; fails=$((fails+1)); else echo "  ok   - block v1 da bi go"; fi
grep -q "echo \"hook chay\"" "$HOOK"
check "phan con lai cua hook duoc giu nguyen" $?
bash -n "$HOOK"
check "hook van hop le (bash -n)" $?

cp "$HOOK" "$TMP/hook.after1"
python3 "$INJECT" "$HOOK" "/home/hatch/workspace/muse-platform-setup/tunnel/reverse-tunnel.sh" \
  "/home/hatch/workspace/muse-platform-setup/keys/muse-agent-ed25519" \
  "/home/hatch/workspace/muse-platform-setup/tunnel/ts-socat-proxy.sh" \
  "testuser" "100.64.0.1" >/dev/null
diff -q "$TMP/hook.after1" "$HOOK" >/dev/null
check "inject lai khong doi file (idempotent)" $?

n=$(grep -c "muse-bridge watchdog v3] BEGIN" "$HOOK")
[ "$n" = "1" ]
check "chi co 1 block v2" $?

echo
if [ "$fails" = "0" ]; then echo "WATCHDOG_TEST: PASS"; else echo "WATCHDOG_TEST: FAIL ($fails)"; fi
exit "$fails"
