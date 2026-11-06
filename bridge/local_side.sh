#!/bin/bash
# ==============================================================================
# local_side.sh - Phia may cua nguoi dung (Agent Ngoai).
#
#   arm      : chuan bi moi truong + toan quyen + TOFU + config + push bundle
#   status   : in trang thai kenh
#   inbox    : doc tin nhan gui toi
#   send     : gui tin nhan
#   daemon   : watch inbox -> log + thong bao desktop
#   prompt   : render MUSE_PROMPT.md cho may Muse
#   push     : day bridge.py + muse_side.sh len may Muse
#
# Idempotent: chay lai nhieu lan khong sao.
# ==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BRIDGE_PY="$SCRIPT_DIR/bridge.py"
STATE_DIR="${MUSE_BRIDGE_STATE:-$HOME/.muse-bridge}"
CONFIG="$STATE_DIR/config.json"
SPOOL="$STATE_DIR"
LOCAL_KEY="${LOCAL_KEY:-$HOME/.ssh/id_ed25519}"
TS_IP="${TS_IP:-}"
REMOTE_SPOOL="${REMOTE_SPOOL:-/root/.muse-bridge}"

say()  { echo "[bridge] $*"; }
warn() { echo "[bridge][WARN] $*" >&2; }
die()  { echo "[bridge][ERROR] $*" >&2; exit 1; }

# --------------------------------------------------------------------------- ssh helpers
ssh_muse() {
  ssh -p 2222 \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o BatchMode=yes \
      -o ConnectTimeout=15 \
      -o LogLevel=ERROR \
      -i "$LOCAL_KEY" root@127.0.0.1 "$@" < /dev/null
}

# ghi mot file len may Muse: ssh_muse_push <local file> <remote cmd>
ssh_muse_push() {
  local file="$1"; shift
  ssh -p 2222 \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o BatchMode=yes \
      -o ConnectTimeout=15 \
      -o LogLevel=ERROR \
      -i "$LOCAL_KEY" root@127.0.0.1 "$@" < "$file"
}

muse_reachable() { ssh_muse 'true' >/dev/null 2>&1; }

# --------------------------------------------------------------------------- arm
detect_ts_ip() {
  if command -v tailscale >/dev/null 2>&1; then
    TS_IP="$(tailscale ip -4 2>/dev/null | head -n1)"
  fi
  [ -n "$TS_IP" ] || TS_IP="$(ip -brief addr show tailscale0 2>/dev/null | awk '{print $3}' | cut -d/ -f1)"
  echo "$TS_IP"
}

ensure_sshd() {
  if ss -tln 2>/dev/null | grep -q ':22\b'; then
    say "sshd: listening on :22"
    return 0
  fi
  say "sshd: not listening on :22 -> trying to start"
  sudo -n systemctl enable --now ssh >/dev/null 2>&1 || sudo -n systemctl enable --now sshd >/dev/null 2>&1 || true
  if ! ss -tln 2>/dev/null | grep -q ':22\b'; then
    warn "sshd chua len duoc. Chay: sudo systemctl enable --now ssh   (can quyen root 1 lan)"
    return 1
  fi
  say "sshd: started"
}

ensure_key() {
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  if [ ! -f "$LOCAL_KEY" ]; then
    say "sinh key moi: $LOCAL_KEY"
    ssh-keygen -t ed25519 -f "$LOCAL_KEY" -N "" -C "muse-bridge-local" >/dev/null
  fi
  chmod 600 "$LOCAL_KEY" 2>/dev/null || true
  chmod 644 "${LOCAL_KEY}.pub" 2>/dev/null || true
}

# --- TOFU: tu dong pin key cua may Muse moi (bat buoc user copy/paste pubkey) ---
install_authorizer() {
  install -m 700 "$SCRIPT_DIR/authorize_peer.sh" "$STATE_DIR/authorize_peer.sh"
  touch "$STATE_DIR/tofu.enabled"
  chmod 600 "$STATE_DIR/tofu.enabled"
  say "authorizer: $STATE_DIR/authorize_peer.sh"
}

install_sshd_hook() {
  local installer="$REPO_DIR/scripts/install_tofu_hook.sh"
  if ! command -v sshd >/dev/null 2>&1 && [ ! -x /usr/sbin/sshd ]; then
    warn "khong tim thay sshd -> bo qua TOFU hook"
    return 1
  fi
  if ! sudo -n true 2>/dev/null; then
    warn "TOFU hook can quyen root. Chay 1 lan (nhap mat khau cua may):"
    warn "    sudo bash $installer"
    warn "Sau do moi may Muse (key moi) se tu duoc sshd chap nhan - khong con copy/paste pubkey."
    return 1
  fi
  sudo -n bash "$installer" && say "TOFU hook: da cai" || warn "cai TOFU hook that bai"
}

write_config() {
  mkdir -p "$STATE_DIR" "$SPOOL"/{inbox,outbox,pending,read,logs}
  chmod 700 "$STATE_DIR"
  local key="$LOCAL_KEY"
  cat > "$CONFIG" <<EOF
{
  "role": "local",
  "spool": "$SPOOL",
  "peer": {
    "role": "muse",
    "transport": "ssh",
    "host": "127.0.0.1",
    "port": 2222,
    "user": "root",
    "spool": "$REMOTE_SPOOL",
    "ssh_opts": ["-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "LogLevel=ERROR", "-i", "$key"]
  }
}
EOF
  say "config: $CONFIG"
}

install_bundle_local() {
  mkdir -p "$STATE_DIR/bundle"
  install -m 0755 "$BRIDGE_PY" "$STATE_DIR/bridge.py"
  install -m 0755 "$SCRIPT_DIR/muse_side.sh" "$STATE_DIR/bundle/muse_side.sh"
  say "bundle: $STATE_DIR/bridge.py + $STATE_DIR/bundle/muse_side.sh"
}

push_bundle() {
  if ! muse_reachable; then
    warn "khong ket noi duoc toi Muse (127.0.0.1:2222) -> skip push bundle"
    return 1
  fi
  ssh_muse "mkdir -p $REMOTE_SPOOL/bundle /root/.ssh && chmod 700 /root/.ssh" >/dev/null 2>&1 || true
  ssh_muse_push "$BRIDGE_PY" "cat > $REMOTE_SPOOL/bridge.py" || { warn "push bridge.py that bai"; return 1; }
  ssh_muse_push "$SCRIPT_DIR/muse_side.sh" "cat > $REMOTE_SPOOL/muse_side.sh" || { warn "push muse_side.sh that bai"; return 1; }
  ssh_muse_push "$SCRIPT_DIR/inject_watchdog.py" "cat > $REMOTE_SPOOL/inject_watchdog.py" || true
  ssh_muse_push "$SCRIPT_DIR/muse_side.sh" "cat > $REMOTE_SPOOL/bundle/muse_side.sh" || true
  ssh_muse_push "$SCRIPT_DIR/inject_watchdog.py" "cat > $REMOTE_SPOOL/bundle/inject_watchdog.py" || true
  ssh_muse "chmod 700 $REMOTE_SPOOL $REMOTE_SPOOL/bridge.py $REMOTE_SPOOL/muse_side.sh $REMOTE_SPOOL/inject_watchdog.py $REMOTE_SPOOL/bundle/muse_side.sh $REMOTE_SPOOL/bundle/inject_watchdog.py; chmod 600 $REMOTE_SPOOL/bridge.py" >/dev/null 2>&1 || true
  say "bundle da duoc day len Muse ($REMOTE_SPOOL)"
}

cmd_arm() {
  local do_tofu=1 do_push=1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --no-tofu) do_tofu=0 ;;
      --no-push) do_push=0 ;;
      *) die "tham so la: $1" ;;
    esac
    shift
  done
  say "=== ARM phia may ngoai ==="
  TS_IP="$(detect_ts_ip)"
  [ -n "$TS_IP" ] || warn "khong detect duoc IP Tailscale"
  say "tailscale ip: ${TS_IP:-unknown}"
  ensure_sshd || true
  ensure_key
  install_bundle_local
  install_authorizer
  [ "$do_tofu" = "1" ] && install_sshd_hook
  write_config
  if [ "$do_push" = "1" ]; then push_bundle || true; fi
  echo
  bash "$SCRIPT_DIR/../scripts/bridge.sh" status 2>/dev/null || true
  echo
  say "buoc tiep theo: chay 'bash scripts/bridge.sh prompt' va dan prompt do vao chat cua Agent Muse"
}

cmd_status() {
  python3 "$STATE_DIR/bridge.py" status "$@"
}

cmd_inbox() {
  python3 "$STATE_DIR/bridge.py" inbox "$@"
}

cmd_send() {
  python3 "$STATE_DIR/bridge.py" send "$@"
}

cmd_ack() {
  python3 "$STATE_DIR/bridge.py" ack "$@"
}

cmd_sync() {
  python3 "$STATE_DIR/bridge.py" sync "$@"
}

cmd_daemon() {
  local interval="${1:-3}"
  mkdir -p "$STATE_DIR/logs"
  local log="$STATE_DIR/logs/inbox.log"
  say "daemon: watching $SPOOL/inbox (Ctrl-C de dung)"

  # vong lap gui lai tin pending (chay nen)
  ( while true; do
      python3 "$STATE_DIR/bridge.py" sync >>"$log" 2>&1 || true
      sleep 10
    done ) &
  SYNC_PID=$!
  trap '[ -n "${SYNC_PID:-}" ] && kill "$SYNC_PID" 2>/dev/null' EXIT INT TERM

  python3 "$STATE_DIR/bridge.py" inbox --watch --interval "$interval" 2>/dev/null | while IFS= read -r line; do
    [ -z "$line" ] && continue
    printf '%s %s\n' "$(date -Is)" "$line" >> "$log"
    case "$line" in
      *type=QUESTION*|*type=TASK*)
        command -v notify-send >/dev/null 2>&1 && \
          notify-send "muse-bridge" "$(printf '%s' "$line" | head -c 200)" 2>/dev/null || true
        ;;
    esac
  done
}

cmd_prompt() {
  python3 "$REPO_DIR/scripts/render_prompt.py" "$@"
}

cmd_push() { push_bundle; }

case "${1:-}" in
  arm)      shift; cmd_arm "$@" ;;
  status)   shift; cmd_status "$@" ;;
  inbox)    shift; cmd_inbox "$@" ;;
  send)     shift; cmd_send "$@" ;;
  ack)      shift; cmd_ack "$@" ;;
  sync)     shift; cmd_sync "$@" ;;
  daemon)   shift; cmd_daemon "$@" ;;
  prompt)   shift; cmd_prompt "$@" ;;
  push)     shift; cmd_push "$@" ;;
  *) echo "usage: local_side.sh {arm|status|inbox|send|ack|sync|daemon|prompt|push}"; exit 2 ;;
esac
