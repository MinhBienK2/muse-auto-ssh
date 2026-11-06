#!/bin/bash
# ==============================================================================
# install_tofu_hook.sh - Cai "trust on first use" cho sshd (can root, 1 lan).
#
#   sudo bash scripts/install_tofu_hook.sh
#
# Sau khi cai: moi may Muse (key moi) se duoc sshd tu dong pin khi no ket noi
# tu trong tailnet Tailscale -> nguoi dung khong con phai copy/paste pubkey nua.
# ==============================================================================
set -euo pipefail

USER_NAME="${SUDO_USER:-$(id -un)}"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
STATE_DIR="$USER_HOME/.muse-bridge"
CONF="/etc/ssh/sshd_config.d/99-muse-bridge.conf"

if [ "$(id -u)" != "0" ]; then
  echo "can quyen root: sudo bash $0" >&2
  exit 1
fi

install -d -m 700 -o "$USER_NAME" -g "$USER_NAME" "$STATE_DIR"
install -d -m 700 -o "$USER_NAME" -g "$USER_NAME" "$STATE_DIR/peers"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$REPO_DIR/bridge/authorize_peer.sh" ]; then
  install -m 700 "$REPO_DIR/bridge/authorize_peer.sh" "$STATE_DIR/authorize_peer.sh"
else
  echo "khong tim thay bridge/authorize_peer.sh" >&2
  exit 1
fi

chown "$USER_NAME:$USER_NAME" "$STATE_DIR/authorize_peer.sh"
chmod 700 "$STATE_DIR/authorize_peer.sh"
touch "$STATE_DIR/tofu.enabled"
chown "$USER_NAME:$USER_NAME" "$STATE_DIR/tofu.enabled"
chmod 600 "$STATE_DIR/tofu.enabled"

if [ -f "$CONF" ]; then cp "$CONF" "$CONF.bak.$(date +%s)"; fi
cat > "$CONF" <<EOF
# muse-bridge: tu pin (TOFU) key cua may Muse moi trong tailnet Tailscale.
Match User $USER_NAME
    AuthorizedKeysFile $USER_HOME/.ssh/authorized_keys
    AuthorizedKeysCommand $STATE_DIR/authorize_peer.sh %u %h %k %t
    AuthorizedKeysCommandUser $USER_NAME
EOF
chmod 644 "$CONF"

if ! /usr/sbin/sshd -t; then
  echo "sshd -t that bai -> khoi phuc config cu" >&2
  [ -f "$CONF.bak."* ] && cp "$(ls -t "$CONF".bak.* | head -1)" "$CONF"
  exit 1
fi

systemctl reload ssh 2>/dev/null || systemctl restart ssh 2>/dev/null || service ssh reload
echo "TOFU hook da cai: $CONF"
echo "Peer da pin: $STATE_DIR/peers/  (log: $STATE_DIR/peers.log)"
