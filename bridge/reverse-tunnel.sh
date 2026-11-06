#!/bin/bash
# ==============================================================================
# reverse-tunnel.sh - Vong lap tu reconnect reverse SSH tunnel (Muse -> may ngoai)
#
# Dong vai tro "watchdog" khong phu thuoc Hatch hook: vua giu tunnel song,
# vua kiem tra sshd co tra loi BANNER duoc khong (sshd treo la nguyen nhan
# chan keo toi may ngoai).
#
# Bien (ghi tu setup): LOCAL_IP, LOCAL_USER, REMOTE_PORT, KEY_PATH, PROXY_PATH
# ==============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/tunnel.conf"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

LOCAL_USER="${LOCAL_USER:-minhbien}"
LOCAL_IP="${LOCAL_IP:-100.120.205.53}"
REMOTE_PORT="${REMOTE_PORT:-2222}"
KEY_PATH="${KEY_PATH:-/home/hatch/.ssh/id_ed25519}"
PROXY_PATH="${PROXY_PATH:-$SCRIPT_DIR/ts-socat-proxy.sh}"
LOG="${TUNNEL_LOG:-$SCRIPT_DIR/tunnel.log}"

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

sshd_alive() {
  # sshd "chay" chua du - phai tra loi banner tren :22
  timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/22; head -c 4 <&3' 2>/dev/null | grep -q SSH
}

ensure_sshd() {
  mkdir -p /run/sshd /var/run/sshd
  if ! pgrep -x sshd >/dev/null 2>&1; then
    /usr/sbin/sshd 2>/dev/null || true
    sleep 1
  fi
  if ! sshd_alive; then
    log "sshd khong tra loi banner -> restart"
    pkill -x sshd >/dev/null 2>&1 || true
    sleep 1
    /usr/sbin/sshd 2>/dev/null || true
    sleep 2
    sshd_alive && log "sshd da khoi dong lai" || log "sshd van khong phan hoi"
  fi
}

log "loop start -> ${LOCAL_USER}@${LOCAL_IP}:${REMOTE_PORT} (key $KEY_PATH)"

while true; do
  ensure_sshd
  ssh -N -R "${REMOTE_PORT}:127.0.0.1:22" \
    -o "ProxyCommand=${PROXY_PATH} %h %p" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 \
    -o ConnectTimeout=15 \
    -i "$KEY_PATH" "${LOCAL_USER}@${LOCAL_IP}"
  log "tunnel exit ($?). reconnect sau 10s"
  sleep 10
done
