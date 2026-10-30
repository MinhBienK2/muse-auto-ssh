#!/bin/bash
# ==============================================================================
# muse_start_tunnel.sh - Stage 2: Authorize Local Key & Launch Reverse Tunnel
# Usage: bash scripts/muse_start_tunnel.sh <LOCAL_IP> <LOCAL_USER> "<LOCAL_PUBLIC_KEY>"
# ==============================================================================
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "Usage: $0 <LOCAL_IP> <LOCAL_USER> \"<LOCAL_PUBLIC_KEY>\""
  echo "Example: $0 100.120.205.53 minhbien \"ssh-ed25519 AAAAC... phamm@minhbien\""
  exit 1
fi

LOCAL_IP="$1"
LOCAL_USER="$2"
LOCAL_PUB_KEY="$3"

echo "=========================================="
echo " [Muse Agent] Configuring Reverse Tunnel  "
echo " Target: ${LOCAL_USER}@${LOCAL_IP}        "
echo "=========================================="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TUNNEL_DIR="$HOME/workspace/muse-platform-setup/tunnel"
mkdir -p "$TUNNEL_DIR" "$HOME/.ssh" /root/.ssh

# 1. Authorize Local Public Key on Muse
echo "[+] Adding Local Public Key to authorized_keys..."
mkdir -p "$HOME/.ssh"
grep -qxF "$LOCAL_PUB_KEY" "$HOME/.ssh/authorized_keys" 2>/dev/null || echo "$LOCAL_PUB_KEY" >> "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"

if [ -d "/root/.ssh" ] && [ "$HOME" != "/root" ]; then
  grep -qxF "$LOCAL_PUB_KEY" /root/.ssh/authorized_keys 2>/dev/null || echo "$LOCAL_PUB_KEY" >> /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
fi

# 2. Setup Tunnel Configuration
cat << EOF > "$TUNNEL_DIR/tunnel.conf"
LOCAL_IP="$LOCAL_IP"
LOCAL_USER="$LOCAL_USER"
REMOTE_PORT="2222"
EOF

# 3. Deploy scripts to tunnel directory
cp "$SCRIPT_DIR/templates/ts-socat-proxy.sh" "$TUNNEL_DIR/ts-socat-proxy.sh"
cp "$SCRIPT_DIR/templates/reverse-tunnel.sh" "$TUNNEL_DIR/reverse-tunnel.sh"
chmod +x "$TUNNEL_DIR/ts-socat-proxy.sh" "$TUNNEL_DIR/reverse-tunnel.sh"

# 4. Stop any old instance of reverse-tunnel
pkill -f "reverse-tunnel" || true
sleep 1

# 5. Start Tunnel in Background
echo "[+] Starting background reverse tunnel loop..."
nohup /bin/bash "$TUNNEL_DIR/reverse-tunnel.sh" > "$TUNNEL_DIR/tunnel.log" 2>&1 &
sleep 2

# Check status
if pgrep -f "reverse-tunnel.sh" >/dev/null; then
  echo "✅ Reverse tunnel loop started successfully (PID: $(pgrep -f "reverse-tunnel.sh"))"
  echo "Log output ($TUNNEL_DIR/tunnel.log):"
  tail -n 5 "$TUNNEL_DIR/tunnel.log" || true
  echo ""
  echo "------------------------------------------------------------------"
  echo "👉 Inform Local Agent: Reverse tunnel is active!"
  echo "Local Agent can now test: ssh -p 2222 root@localhost (or ssh muse)"
  echo "------------------------------------------------------------------"
else
  echo "❌ Error: Reverse tunnel process did not start. Check $TUNNEL_DIR/tunnel.log:"
  cat "$TUNNEL_DIR/tunnel.log" || true
  exit 1
fi
