#!/bin/bash
# ==============================================================================
# local_finalize_persistence.sh - Stage 4: Test Connection & Harden Remote Muse
# Run this on Local Machine after Muse runs muse_start_tunnel.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================================="
echo " [Local Agent] Finalizing Muse Connection & Persistence    "
echo "=========================================================="

echo "[1/3] Waiting for Reverse Tunnel port 2222 to become active..."
MAX_RETRIES=30
COUNT=0
CONNECTED=false

while [ "$COUNT" -lt "$MAX_RETRIES" ]; do
  if ss -tln 2>/dev/null | grep -q ":2222\b"; then
    CONNECTED=true
    break
  fi
  COUNT=$((COUNT + 1))
  printf "."
  sleep 2
done
echo ""

if [ "$CONNECTED" = false ]; then
  echo "❌ Timeout waiting for port 2222. Please make sure Agent Muse ran muse_start_tunnel.sh."
  exit 1
fi
echo "  -> Port 2222 is active (LISTEN)!"

echo "[2/3] Verifying initial SSH connection into Muse VM..."
REMOTE_HOST=$(ssh -o ConnectTimeout=5 -o BatchMode=yes muse hostname 2>/dev/null || echo "")
if [ -z "$REMOTE_HOST" ]; then
  echo "❌ SSH connection test to 'muse' failed! Please verify keys and port 2222."
  exit 1
fi
echo "  -> Connected successfully to Muse VM (Hostname: ${REMOTE_HOST})!"

echo "[3/3] Deploying multi-layer persistence & self-healing to Muse VM..."
ssh muse 'bash -s' < "$SCRIPT_DIR/muse_harden_persistence.sh"

echo ""
echo "=========================================================="
echo "🎉 ALL DONE! The SSH bridge is fully automated & hardened!"
echo "You can now connect to Muse anytime using:"
echo "   ssh muse"
echo "=========================================================="
