#!/bin/bash
# ==============================================================================
# muse_bootstrap.sh - Stage 1 Initialization on Muse Secure VM
# Run this inside Muse VM (root@htch-runtime)
# ==============================================================================
set -euo pipefail

echo "=========================================="
echo " [Muse Agent] Initializing Muse VM Setup  "
echo "=========================================="

# 1. Ensure socat is installed
if ! command -v socat >/dev/null 2>&1; then
  echo "[+] Installing socat..."
  apt-get update -qq && apt-get install -y -qq socat
fi

# 2. Ensure OpenSSH server is running on Muse port 22
if ! command -v sshd >/dev/null 2>&1; then
  echo "[+] Installing openssh-server..."
  apt-get update -qq && apt-get install -y -qq openssh-server
fi

mkdir -p /var/run/sshd
if ! pgrep -x sshd >/dev/null 2>&1; then
  echo "[+] Starting local sshd daemon on port 22..."
  /usr/sbin/sshd || true
fi

# 3. Ensure SSH key exists for Muse
KEY_DIR="$HOME/workspace/muse-platform-setup/keys"
KEY_FILE="$KEY_DIR/muse-agent-ed25519"

if [ ! -f "$KEY_FILE" ]; then
  if [ -f "$HOME/.ssh/id_ed25519" ]; then
    KEY_FILE="$HOME/.ssh/id_ed25519"
  else
    mkdir -p "$KEY_DIR"
    echo "[+] Generating ed25519 SSH keypair..."
    ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "muse-external-agent"
  fi
fi

PUB_KEY=$(cat "${KEY_FILE}.pub")

echo ""
echo "------------------------------------------------------------------"
echo "✅ Muse SSH Server & Keypair are READY!"
echo ""
echo "📋 MUSE PUBLIC KEY (Copy this and provide it to Local Agent):"
echo ""
echo "$PUB_KEY"
echo ""
echo "------------------------------------------------------------------"
echo "👉 NEXT STEP FOR MUSE AGENT:"
echo "Wait for the user/Local Agent to provide:"
echo "  1. Local Machine Tailscale IP (e.g. 100.64.0.1)"
echo "  2. Local Machine Username (e.g. legacy-user)"
echo "  3. Local Machine Public Key (ssh-ed25519 AAAAC...)"
echo ""
echo "Then run:"
echo "  bash scripts/muse_start_tunnel.sh <LOCAL_IP> <LOCAL_USER> \"<LOCAL_PUBLIC_KEY>\""
echo "------------------------------------------------------------------"
