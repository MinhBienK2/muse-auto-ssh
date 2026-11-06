#!/bin/bash
# Reverse tunnel: Muse (this VM) -> G3 (minhbien@100.120.205.53)
# Opens G3 localhost:2222 -> Muse localhost:22. Auto-reconnect loop.
KEY="/home/hatch/workspace/muse-platform-setup/keys/muse-agent-ed25519"
PROXY="/home/hatch/workspace/muse-platform-setup/tunnel/ts-socat-proxy.sh"
TARGET="minhbien@100.120.205.53"


while true; do
  # Ensure local sshd directory and service are running
  mkdir -p /run/sshd /var/run/sshd
  if ! pgrep -x sshd >/dev/null 2>&1; then
    /usr/sbin/sshd 2>/dev/null || true
  fi

  echo "[$(date '+%F %T')] starting tunnel to $TARGET..."
  ssh -N -R 2222:127.0.0.1:22 \
    -o "ProxyCommand=$PROXY %h %p" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
    -o ConnectTimeout=10 \
    -i "$KEY" "$TARGET"
  echo "[$(date '+%F %T')] tunnel exited ($?), reconnect in 10s"
  sleep 10
done
