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
# Config rieng theo port: reverse-tunnel-<port>.sh -> tunnel-<port>.conf.
# Neu khong co config theo port thi fallback ve tunnel.conf (the he).
PORT="$(basename "${BASH_SOURCE[0]}" .sh | sed -n 's/^reverse-tunnel-\([0-9]\+\)$/\1/p')"
CONFIG_FILE="$SCRIPT_DIR/tunnel-${PORT:-default}.conf"
[ -f "$CONFIG_FILE" ] || CONFIG_FILE="$SCRIPT_DIR/tunnel.conf"
# shellcheck source=/dev/null
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

# LOCAL_IP / LOCAL_USER / REMOTE_PORT deu den tu tunnel-<port>.conf (sinh boi may ngoai).
# Khong hard-code gia tri may cua mot nguoi cu the nao - may nao cung dung duoc.
: "${LOCAL_IP:?thieu LOCAL_IP trong $CONFIG_FILE}"
: "${LOCAL_USER:?thieu LOCAL_USER trong $CONFIG_FILE}"
REMOTE_PORT="${REMOTE_PORT:-2222}"
KEY_PATH="${KEY_PATH:-/home/hatch/.ssh/id_ed25519}"
PROXY_PATH="${PROXY_PATH:-$SCRIPT_DIR/ts-socat-proxy.sh}"
LOG="${TUNNEL_LOG:-$SCRIPT_DIR/tunnel.log}"

LOOP_VERSION="v5"
log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

sshd_alive() {
  # sshd "chay" chua du - phai tra loi banner tren :22
  timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/22; head -c 4 <&3' 2>/dev/null | grep -q SSH
}

ensure_authorized_keys() {
  # Container refresh -> /root (overlay) bi xoa -> key may ngoai mat.
  # Khoi phuc bang COPY tu seed ben vung (KHONG symlink: /home/hatch group-writable
  # -> sshd StrictModes se tu choi key).
  local seed="/home/hatch/.muse-bridge/authorized_keys.seed"
  local ak="/root/.ssh/authorized_keys"
  mkdir -p /root/.ssh; chmod 700 /root/.ssh 2>/dev/null || true
  if [ -L "$ak" ]; then rm -f "$ak"; fi
  if [ ! -f "$ak" ] && [ -f "$seed" ]; then
    cp -f "$seed" "$ak" 2>/dev/null || true
    chmod 600 "$ak" 2>/dev/null || true
    log "da khoi phuc authorized_keys tu seed ben vung"
  fi
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

# --- tu keo ban moi tu may ngoai (huong container -> local qua proxy) ----------
# Huong nay LUON hoat dong (key cua container da duoc may ngoai authorize),
# nen container tu cai lai duoc du may ngoai khong vao duoc container.
pull_updates() {
  local base="/home/hatch/.muse-bridge"
  local bundle="$base/bundle"
  local ver
  ver=$(timeout 25 ssh -n -o "ProxyCommand=${PROXY_PATH} %h %p" -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10 \
        -i "$KEY_PATH" "${LOCAL_USER}@${LOCAL_IP}" 'cat ~/.muse-bridge/bundle/VERSION 2>/dev/null' 2>/dev/null | tr -d '\r')
  [ -n "$ver" ] || return 0
  [ "$ver" = "$(cat "$base/.version" 2>/dev/null)" ] && return 0
  mkdir -p "$bundle"
  local f
  for f in bridge.py muse_side.sh inject_watchdog.py reverse-tunnel.sh ts-socat-proxy.sh; do
    timeout 25 ssh -n -o "ProxyCommand=${PROXY_PATH} %h %p" -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10 \
      -i "$KEY_PATH" "${LOCAL_USER}@${LOCAL_IP}" "cat ~/.muse-bridge/bundle/$f" > "$bundle/$f.new" 2>/dev/null || return 0
    [ -s "$bundle/$f.new" ] || return 0
  done
  local hook="/home/hatch/hooks/scripts/muse-platform-boot.sh"
  for f in bridge.py muse_side.sh inject_watchdog.py reverse-tunnel.sh ts-socat-proxy.sh; do
    mv -f "$bundle/$f.new" "$bundle/$f"; chmod 700 "$bundle/$f"
  done
  cp -f "$bundle/bridge.py" "$base/bridge.py" 2>/dev/null || true
  if [ -f "$hook" ] && [ -f "$base/inject_watchdog.py" ]; then
    python3 "$base/inject_watchdog.py" "$hook" "$SCRIPT_DIR/reverse-tunnel-${REMOTE_PORT}.sh" \
      "$KEY_PATH" "$PROXY_PATH" "$LOCAL_USER" "$LOCAL_IP" >/dev/null 2>&1 || true
  fi
  printf '%s\n' "$ver" > "$base/.version"
  log "da tu keo bundle moi tu may ngoai (version $ver)"
}

pull_updates
# ghi version de watchdog biet khi can restart (script da duoc nang cap)
printf '%s\n' "$LOOP_VERSION" > "$(dirname "$LOG")/.loop_version" 2>/dev/null || true

PULL_EVERY=5
PULL_N=0
while true; do
  ensure_authorized_keys
  ensure_sshd
  PULL_N=$((PULL_N + 1))
  if [ "$PULL_N" -ge "$PULL_EVERY" ]; then
    PULL_N=0
    pull_updates || true
  fi
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
