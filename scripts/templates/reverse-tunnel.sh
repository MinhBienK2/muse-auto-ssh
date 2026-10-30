#!/bin/bash
# ==============================================================================
# reverse-tunnel.sh - Auto-reconnecting Reverse SSH Tunnel: Muse VM -> Local Host
# ==============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/tunnel.conf"

if [ -f "$CONFIG_FILE" ]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

LOCAL_USER="${LOCAL_USER:-minhbien}"
LOCAL_IP="${LOCAL_IP:-100.120.205.53}"
REMOTE_PORT="${REMOTE_PORT:-2222}"
KEY_PATH="${KEY_PATH:-$HOME/workspace/muse-platform-setup/keys/muse-agent-ed25519}"
PROXY_PATH="${PROXY_PATH:-$SCRIPT_DIR/ts-socat-proxy.sh}"

# Fallback for key location
if [ ! -f "$KEY_PATH" ] && [ -f "$HOME/.ssh/id_ed25519" ]; then
  KEY_PATH="$HOME/.ssh/id_ed25519"
fi

# Ensure local sshd on Muse is running
if ! pgrep -x sshd >/dev/null 2>&1; then
  /usr/sbin/sshd 2>/dev/null || true
fi

echo "[$(date '+%F %T')] Starting reverse tunnel to ${LOCAL_USER}@${LOCAL_IP} (Forwarding port ${REMOTE_PORT} -> localhost:22)..."

while true; do
  ssh -N -R "${REMOTE_PORT}:127.0.0.1:22" \
    -o "ProxyCommand=${PROXY_PATH} %h %p" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 \
    -o ConnectTimeout=10 \
    -i "$KEY_PATH" "${LOCAL_USER}@${LOCAL_IP}"
  
  EXIT_CODE=$?
  echo "[$(date '+%F %T')] Reverse tunnel exited (code ${EXIT_CODE}). Reconnecting in 10s..."
  sleep 10
done
