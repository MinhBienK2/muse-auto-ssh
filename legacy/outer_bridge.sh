#!/bin/bash
# ==============================================================================
# outer_bridge.sh - Kiem tra trang thai phia may ngoai (Agent Ngoai).
# Dung khi can biet da setup xong chua, va doc trang thai moi nhat cua Muse.
# ==============================================================================
set -uo pipefail

MAILBOX="${MAILBOX:-$HOME/muse-bridge}"

echo "===== OUTER_BRIDGE_STATUS ====="
echo "HOST=$(hostname)"
echo "TS_IP=$(tailscale ip -4 2>/dev/null || echo unknown)"
echo "SSHD=$(systemctl is-active ssh 2>/dev/null || echo inactive)"
if ss -tln 2>/dev/null | grep -q ':22\b'; then echo "PORT22=LISTEN"; else echo "PORT22=DOWN"; fi
if ss -tln 2>/dev/null | grep -q ':2222\b'; then echo "PORT2222=LISTEN"; else echo "PORT2222=DOWN"; fi
if grep -q "Host muse" "$HOME/.ssh/config" 2>/dev/null; then echo "SSH_ALIAS=OK"; else echo "SSH_ALIAS=MISSING"; fi

REMOTE_HOST=$(ssh -o ConnectTimeout=5 -o BatchMode=yes muse hostname 2>/dev/null || echo "")
if [ -n "$REMOTE_HOST" ]; then
  echo "SSH_MUSE=OK host=$REMOTE_HOST"
else
  echo "SSH_MUSE=DOWN"
fi

echo "AUTHORIZED_KEYS:"
sed 's/^/  /' "$HOME/.ssh/authorized_keys" 2>/dev/null || echo "  (none)"

echo "MAILBOX_STATUS:"
if [ -f "$MAILBOX/MUSE_STATUS.md" ]; then
  sed 's/^/  /' "$MAILBOX/MUSE_STATUS.md"
else
  echo "  (chua co MUSE_STATUS.md)"
fi

echo "OUTER_TASKS_PENDING:"
if [ -f "$MAILBOX/OUTER_TASKS.md" ]; then
  sed 's/^/  /' "$MAILBOX/OUTER_TASKS.md"
else
  echo "  (chua co OUTER_TASKS.md)"
fi
echo "===== END ====="
