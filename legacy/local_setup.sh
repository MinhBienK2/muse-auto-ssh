#!/bin/bash
# ==============================================================================
# local_setup.sh - Setup Local Machine (Linux/macOS/WSL)
# Usage: bash scripts/local_setup.sh "<MUSE_PUBLIC_KEY>"
# ==============================================================================
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 \"<MUSE_PUBLIC_KEY>\""
  echo "Example: $0 \"ssh-ed25519 AAAAC... muse-external-agent\""
  exit 1
fi

MUSE_PUB_KEY="$1"
CURRENT_USER=$(whoami)

echo "=========================================="
echo " [Local Agent] Configuring Local Machine  "
echo " User: $CURRENT_USER                      "
echo "=========================================="

# 1. Check OpenSSH Server on Port 22
echo "[1/4] Checking OpenSSH Server..."
if ! command -v sshd >/dev/null 2>&1; then
  echo "⚠️ OpenSSH Server is not installed on this machine!"
  echo "Please run: sudo apt update && sudo apt install -y openssh-server && sudo systemctl enable --now ssh"
  exit 1
fi

if ! ss -tlnp 2>/dev/null | grep -q ":22\b"; then
  echo "⚠️ Port 22 is not listening. Attempting to start ssh..."
  sudo systemctl start ssh 2>/dev/null || sudo systemctl start sshd 2>/dev/null || true
  if ! ss -tlnp 2>/dev/null | grep -q ":22\b"; then
    echo "❌ Port 22 still not listening. Please ensure ssh service is active."
    exit 1
  fi
fi
echo "  -> SSH Server is active on port 22."

# 2. Detect Tailscale IPv4
echo "[2/4] Detecting Tailscale IP..."
if command -v tailscale >/dev/null 2>&1; then
  LOCAL_TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
else
  LOCAL_TAILSCALE_IP=""
fi

if [ -z "$LOCAL_TAILSCALE_IP" ]; then
  LOCAL_TAILSCALE_IP=$(ip -brief addr show tailscale0 2>/dev/null | awk '{print $3}' | cut -d/ -f1 || echo "")
fi

if [ -z "$LOCAL_TAILSCALE_IP" ]; then
  echo "⚠️ Could not auto-detect Tailscale IP. Please ensure Tailscale is connected."
  read -r -p "Enter your Tailscale IP manually: " LOCAL_TAILSCALE_IP
fi
echo "  -> Tailscale IP: $LOCAL_TAILSCALE_IP"

# 3. Ensure Local SSH Keypair exists & authorize Muse
echo "[3/4] Setting up SSH keys..."
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

LOCAL_KEY="$HOME/.ssh/id_ed25519"
if [ ! -f "$LOCAL_KEY" ]; then
  echo "  -> Generating ed25519 key..."
  ssh-keygen -t ed25519 -f "$LOCAL_KEY" -N "" -C "${CURRENT_USER}@$(hostname)"
fi
LOCAL_PUB_KEY=$(cat "${LOCAL_KEY}.pub")

# Authorize Muse Public Key
grep -qxF "$MUSE_PUB_KEY" "$HOME/.ssh/authorized_keys" 2>/dev/null || echo "$MUSE_PUB_KEY" >> "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
echo "  -> Muse Public Key added to authorized_keys."

# 4. Configure ~/.ssh/config alias
echo "[4/4] Updating ~/.ssh/config..."
CONFIG_FILE="$HOME/.ssh/config"
touch "$CONFIG_FILE"

if ! grep -q "Host muse" "$CONFIG_FILE"; then
  cat << EOF >> "$CONFIG_FILE"

# Muse Reverse SSH Tunnel
Host muse
    HostName 127.0.0.1
    Port 2222
    User root
    IdentityFile ~/.ssh/id_ed25519
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
EOF
  echo "  -> Added 'Host muse' alias to $CONFIG_FILE."
else
  echo "  -> 'Host muse' alias already exists in $CONFIG_FILE."
fi
chmod 600 "$CONFIG_FILE"

echo ""
echo "=================================================================="
echo "✅ Local Machine configuration is COMPLETE!"
echo ""
echo "📋 INFORMATION FOR AGENT MUSE:"
echo "------------------------------------------------------------------"
echo "1. Tailscale IP : $LOCAL_TAILSCALE_IP"
echo "2. Local User    : $CURRENT_USER"
echo "3. Local PubKey  : $LOCAL_PUB_KEY"
echo "------------------------------------------------------------------"
echo "👉 Tell Agent Muse to run this exact command inside Muse VM:"
echo ""
echo "bash scripts/muse_start_tunnel.sh $LOCAL_TAILSCALE_IP $CURRENT_USER \"$LOCAL_PUB_KEY\""
echo "------------------------------------------------------------------"
echo "Once Muse runs that command, proceed to run:"
echo "  bash scripts/local_finalize_persistence.sh"
echo "=================================================================="
