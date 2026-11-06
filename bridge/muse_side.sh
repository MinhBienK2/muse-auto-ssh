#!/bin/bash
# ==============================================================================
# muse_side.sh - Phia MUSE (container root@htch-runtime).
#
# Tu chua: duoc embed nguyen van vao MUSE_PROMPT.md => Agent Muse khong can
# clone repo, khong can tai gi tu GitHub.
#
#   setup   --local-host H --local-user U --local-pubkey "ssh-ed25519 ..."
#           [--local-spool /home/user/.muse-bridge]
#   hello | report | send | inbox | ack | status | worker
# ==============================================================================
set -uo pipefail

STATE_DIR="${MUSE_BRIDGE_STATE:-$HOME/.muse-bridge}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_PY="$STATE_DIR/bridge.py"
LOCAL_HOST="${LOCAL_HOST:-}"
LOCAL_USER="${LOCAL_USER:-}"
LOCAL_PUBKEY="${LOCAL_PUBKEY:-}"
LOCAL_SPOOL="${LOCAL_SPOOL:-}"

say()  { echo "[muse-side] $*"; }
warn() { echo "[muse-side][WARN] $*" >&2; }
die()  { echo "[muse-side][ERROR] $*" >&2; exit 1; }

# ------------------------------------------------------------------ detect paths
detect_base() {
  local cand
  for cand in /home/hatch/workspace/muse-platform-setup \
              "$HOME/workspace/muse-platform-setup" \
              /root/workspace/muse-platform-setup; do
    if [ -d "$cand" ]; then BASE="$cand"; return 0; fi
  done
  BASE="/home/hatch/workspace/muse-platform-setup"
  return 1
}

detect_key() {
  local cand
  for cand in "$BASE/keys/muse-agent-ed25519" "$HOME/.ssh/id_ed25519" \
              "$HOME/workspace/muse-platform-setup/keys/muse-agent-ed25519"; do
    if [ -f "$cand" ]; then KEY="$cand"; return 0; fi
  done
  KEY="$BASE/keys/muse-agent-ed25519"
  return 1
}

detect_proxy() {
  local cand
  for cand in "$BASE/tunnel/ts-socat-proxy.sh" "$HOME/workspace/muse-platform-setup/tunnel/ts-socat-proxy.sh"; do
    if [ -f "$cand" ]; then PROXY="$cand"; return 0; fi
  done
  PROXY="$BASE/tunnel/ts-socat-proxy.sh"
  return 1
}

detect_loop() {
  LOOP="$BASE/tunnel/reverse-tunnel-$LOCAL_PORT.sh"
  return 1
}

# ------------------------------------------------------------------ components
ensure_pkgs() {
  if ! command -v socat >/dev/null 2>&1; then
    say "cai socat..."
    (apt-get update -qq && apt-get install -y -qq socat) >/dev/null 2>&1 || true
  fi
  if ! command -v sshd >/dev/null 2>&1 && [ ! -x /usr/sbin/sshd ]; then
    say "cai openssh-server..."
    (apt-get update -qq && apt-get install -y -qq openssh-server) >/dev/null 2>&1 || true
  fi
}

sshd_alive() {
  # sshd "chay" (pgrep) khong du - phai tra loi duoc banner tren :22
  timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/22; head -c 4 <&3' 2>/dev/null | grep -q SSH
}

ensure_sshd() {
  mkdir -p /run/sshd /var/run/sshd
  if ! pgrep -x sshd >/dev/null 2>&1; then
    /usr/sbin/sshd 2>/dev/null || true
  fi
  if ! sshd_alive; then
    warn "sshd khong tra loi banner -> restart"
    pkill -x sshd >/dev/null 2>&1 || true
    sleep 1
    /usr/sbin/sshd 2>/dev/null || true
    sleep 1
  fi
  if sshd_alive; then say "sshd: OK (tra loi banner)"; else warn "sshd: van khong phan hoi"; fi
}

ensure_proxy() {
  mkdir -p "$(dirname "$PROXY")"
  if [ ! -f "$PROXY" ]; then
    say "tao proxy script: $PROXY"
    cat > "$PROXY" <<'TS_EOF'
#!/bin/bash
# Bridge Tailscale -> HTTP CONNECT proxy (hatch-egress-proxy:3130)
if [ -z "${HTTPS_PROXY:-}" ] || [[ "${HTTPS_PROXY}" != *"@"* ]]; then
  for p in $(pgrep -u root -f "python|bash|uvicorn" 2>/dev/null); do
    hp=$(cat /proc/$p/environ 2>/dev/null | tr "\0" "\n" | grep -m1 "^HTTPS_PROXY=" || true)
    if [ -n "$hp" ] && [[ "$hp" == *"@"* ]]; then
      eval "export $hp"
      break
    fi
  done
fi
rest="${HTTPS_PROXY#*://}"
userpass="${rest%%@*}"
puser="${userpass%%:*}"
ppass="${userpass#*:}"
exec socat - "PROXY:hatch-egress-proxy:$1:$2,proxyport=3130,proxyauth=${puser}:${ppass}"
TS_EOF
    chmod +x "$PROXY"
  else
    say "proxy script: $PROXY (da co)"
  fi
}

ensure_loop() {
  # Loop rieng cho tung port: reverse-tunnel-<port>.sh (nhieu Muse host tren cung may)
  local target="$BASE/tunnel/reverse-tunnel-$LOCAL_PORT.sh"
  mkdir -p "$(dirname "$target")"
  if [ -f "$target" ] && grep -q "REMOTE_PORT=\"$LOCAL_PORT\"" "$target" 2>/dev/null; then
    say "loop script: $target (da co)"
  else
    say "tao loop script: $target (port $LOCAL_PORT)"
    local tmp="$target.tmp.$$"
    cat > "$tmp" <<RT_EOF
#!/bin/bash
# Vong lap tu reconnect reverse SSH tunnel: Muse -> may ngoai (port $LOCAL_PORT)
set -u
SCRIPT_DIR="$(cd "$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="\${SCRIPT_DIR}/tunnel.conf"
[ -f "\$CONFIG_FILE" ] && source "\$CONFIG_FILE"
LOCAL_USER="\${LOCAL_USER:-minhbien}"
LOCAL_IP="\${LOCAL_IP:-100.120.205.53}"
REMOTE_PORT="$LOCAL_PORT"
KEY_PATH="\${KEY_PATH:-\$HOME/workspace/muse-platform-setup/keys/muse-agent-ed25519}"
PROXY_PATH="\${PROXY_PATH:-\$SCRIPT_DIR/ts-socat-proxy.sh}"
if [ ! -f "\$KEY_PATH" ] && [ -f "\$HOME/.ssh/id_ed25519" ]; then
  KEY_PATH="\$HOME/.ssh/id_ed25519"
fi
echo "[\$(date '+%F %T')] reverse tunnel -> \${LOCAL_USER}@\${LOCAL_IP}:\${REMOTE_PORT}"
while true; do
  mkdir -p /run/sshd /var/run/sshd
  if ! pgrep -x sshd >/dev/null 2>&1; then
    /usr/sbin/sshd 2>/dev/null || true
  fi
  ssh -N -R "\${REMOTE_PORT}:127.0.0.1:22" \\
    -o "ProxyCommand=\${PROXY_PATH} %h %p" \\
    -o StrictHostKeyChecking=no \\
    -o UserKnownHostsFile=/dev/null \\
    -o BatchMode=yes \\
    -o ExitOnForwardFailure=yes \\
    -o ServerAliveInterval=15 \\
    -o ServerAliveCountMax=3 \\
    -o ConnectTimeout=10 \\
    -i "\$KEY_PATH" "\${LOCAL_USER}@\${LOCAL_IP}"
  echo "[\$(date '+%F %T')] tunnel exit (\$?). reconnect sau 10s"
  sleep 10
done
RT_EOF
    chmod +x "$tmp"
    mv -f "$tmp" "$target"
  fi
  LOOP="$target"
}

ensure_key() {
  mkdir -p "$BASE/keys"
  if [ ! -f "$KEY" ]; then
    say "sinh key moi: $KEY"
    ssh-keygen -t ed25519 -f "$KEY" -N "" -C "muse-external-agent" >/dev/null 2>&1 || true
  fi
  [ -f "$KEY" ] || die "khong tao duoc keypair tai $KEY"
}

authorize_local_key() {
  [ -n "$LOCAL_PUBKEY" ] || { warn "khong co local pubkey -> bo qua authorize"; return 0; }
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  grep -qxF "$LOCAL_PUBKEY" "$HOME/.ssh/authorized_keys" 2>/dev/null || echo "$LOCAL_PUBKEY" >> "$HOME/.ssh/authorized_keys"
  chmod 600 "$HOME/.ssh/authorized_keys"
  say "da authorize key may ngoai trong $HOME/.ssh/authorized_keys"
}

ensure_tunnel() {
  cat > "$BASE/tunnel/tunnel.conf" <<EOF
LOCAL_IP="$LOCAL_HOST"
LOCAL_USER="$LOCAL_USER"
REMOTE_PORT="$LOCAL_PORT"
KEY_PATH="$KEY"
PROXY_PATH="$PROXY"
EOF
  if pgrep -af "ssh -N -R $LOCAL_PORT:" >/dev/null 2>&1; then
    TUNNEL_STATE="ADOPTED"
    say "tunnel: ADOPT (port $LOCAL_PORT da chay, khong restart)"
    pgrep -af "ssh -N -R $LOCAL_PORT:" | sed 's/^/    /'
  elif pgrep -af 'ssh -N -R' >/dev/null 2>&1; then
    warn "co tunnel khac dang chay (khac port) - se mo them tunnel cho port $LOCAL_PORT"
    TUNNEL_STATE="STARTED"
    nohup /bin/bash "$LOOP" >> "$BASE/tunnel/tunnel.log" 2>&1 </dev/null &
    sleep 3
  else
    TUNNEL_STATE="STARTED"
    say "tunnel: STARTED"
    nohup /bin/bash "$LOOP" >> "$BASE/tunnel/tunnel.log" 2>&1 </dev/null &
    sleep 3
    pgrep -af 'ssh -N -R' >/dev/null 2>&1 || warn "loop chua len duoc - xem $BASE/tunnel/tunnel.log"
  fi
}

ensure_persistence() {
  local hook
  hook=""
  for cand in /home/hatch/hooks/scripts/muse-platform-boot.sh \
              "$HOME/hooks/scripts/muse-platform-boot.sh"; do
    [ -f "$cand" ] && { hook="$cand"; break; }
  done
  if [ -z "$hook" ]; then
    warn "khong tim thay hatch boot hook -> dung systemd fallback"
    PERSISTENCE="none"
    return
  fi
  if grep -q "muse-bridge watchdog v2" "$hook"; then
    PERSISTENCE="hatch-hook(15s)"
    say "watchdog v2: da co trong $hook"
    return
  fi
  say "inject/nang cap watchdog vao $hook"
  python3 "$SCRIPT_DIR/inject_watchdog.py" "$hook" "$LOOP" "$KEY" "$PROXY" "$LOCAL_USER" "$LOCAL_HOST" || \
    warn "inject watchdog that bai"
  PERSISTENCE="hatch-hook(15s)"
}

write_config() {
  mkdir -p "$STATE_DIR"/{inbox,outbox,pending,read,logs}
  chmod 700 "$STATE_DIR"
  local transport="${MUSE_BRIDGE_TRANSPORT:-ssh}"
  local peer_spool="$LOCAL_SPOOL"
  [ "$transport" = "dir" ] && peer_spool="${MUSE_BRIDGE_PEER_SPOOL:-$LOCAL_SPOOL}"
  cat > "$STATE_DIR/config.json" <<EOF
{
  "role": "muse",
  "spool": "$STATE_DIR",
  "peer": {
    "role": "local",
    "transport": "$transport",
    "host": "$LOCAL_HOST",
    "port": 22,
    "user": "$LOCAL_USER",
    "spool": "$peer_spool",
    "ssh_opts": ["-o", "ProxyCommand=$PROXY $LOCAL_HOST 22", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "BatchMode=yes", "-o", "ConnectTimeout=20", "-o", "LogLevel=ERROR", "-i", "$KEY"]
  }
}
EOF
  say "config: $STATE_DIR/config.json"
}

# ------------------------------------------------------------------ bus helpers
bus() {
  [ -x "$BRIDGE_PY" ] || [ -f "$BRIDGE_PY" ] || die "thieu $BRIDGE_PY"
  python3 "$BRIDGE_PY" "$@"
}

status_report() {
  local host keypath persistence tunnel probe
  host="$(hostname)"
  keypath="$KEY"
  persistence="${PERSISTENCE:-unknown}"
  if pgrep -f 'ssh -N -R' >/dev/null 2>&1; then tunnel="up"; else tunnel="down"; fi
  if bus status --json >/tmp/muse_status.json 2>/dev/null; then probe="OK"; else probe="FAILED"; fi
  cat <<EOF
MUSE_HOST=$host
MUSE_BASE=$BASE
MUSE_KEY=$keypath
MUSE_PUBKEY=$(cat "${KEY}.pub" 2>/dev/null)
MUSE_TUNNEL=${TUNNEL_STATE:-UNKNOWN}/$tunnel
MUSE_TUNNEL_PORT=$LOCAL_PORT
MUSE_PERSISTENCE=$persistence
MUSE_PROBE=$probe
EOF
  cat /tmp/muse_status.json 2>/dev/null
}

# ------------------------------------------------------------------ commands
cmd_setup() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --local-host)   LOCAL_HOST="$2"; shift 2 ;;
      --local-user)   LOCAL_USER="$2"; shift 2 ;;
      --local-pubkey) LOCAL_PUBKEY="$2"; shift 2 ;;
      --local-spool)  LOCAL_SPOOL="$2"; shift 2 ;;
      --local-port)   LOCAL_PORT="$2"; shift 2 ;;
      *) die "tham so la: $1" ;;
    esac
  done
  [ -n "$LOCAL_HOST" ] || die "thieu --local-host"
  [ -n "$LOCAL_USER" ] || die "thieu --local-user"
  [ -n "$LOCAL_SPOOL" ] || LOCAL_SPOOL="/home/$LOCAL_USER/.muse-bridge"

  detect_base || say "tao base moi: $BASE"
  mkdir -p "$BASE"/{keys,tunnel} "$STATE_DIR"/{inbox,outbox,pending,read,logs}
  detect_key; detect_proxy; detect_loop
  ensure_pkgs
  ensure_sshd
  ensure_key
  ensure_proxy
  ensure_loop
  authorize_local_key
  ensure_tunnel
  ensure_persistence
  write_config

  # HELLO + REPORT gui sang may ngoai
  bus send --type HELLO --subject "Muse da len" \
      --body "host=$(hostname) base=$BASE key=$KEY tunnel=${TUNNEL_STATE:-UNKNOWN} ts=$(date -Is)" || true
  bus send --type REPORT --subject "Trang thai Muse" --body-file - <<EOF || true
MUSE_HOST=$(hostname)
MUSE_BASE=$BASE
MUSE_KEY=$KEY
MUSE_PUBKEY=$(cat "${KEY}.pub" 2>/dev/null)
MUSE_TUNNEL=${TUNNEL_STATE:-UNKNOWN}
MUSE_TUNNEL_PORT=$LOCAL_PORT
MUSE_PERSISTENCE=${PERSISTENCE:-unknown}
MUSE_PROXY=$PROXY
MUSE_LOOP=$LOOP
EOF
  echo
  status_report
}

cmd_worker() {
  # Vong lap nhe: bao dam sshd + tunnel con song, ghi log inbox (chi tin moi).
  local interval="${1:-15}"
  local seen="$STATE_DIR/logs/.seen_ids"
  touch "$seen"
  while true; do
    pgrep -x sshd >/dev/null 2>&1 || { mkdir -p /run/sshd /var/run/sshd; /usr/sbin/sshd 2>/dev/null || true; }
    pgrep -f 'ssh -N -R' >/dev/null 2>&1 || {
      nohup /bin/bash "$LOOP" >> "$BASE/tunnel/tunnel.log" 2>&1 </dev/null &
      say "worker: khoi dong lai tunnel"
    }
    bus sync >>"$STATE_DIR/logs/sync.log" 2>&1 || true
    python3 - "$BRIDGE_PY" "$seen" "$STATE_DIR/logs/inbox.log" <<'PYEOF'
import json, os, subprocess, sys
bridge, seen_path, log_path = sys.argv[1:4]
seen = set()
if os.path.exists(seen_path):
    seen = set(open(seen_path).read().split())
try:
    out = subprocess.run(["python3", bridge, "inbox", "--json"],
                         capture_output=True, text=True, timeout=90).stdout
    msgs = json.loads(out or "[]")
except Exception:
    msgs = []
new = []
for m in msgs:
    mid = m.get("id")
    if mid and mid not in seen:
        seen.add(mid)
        new.append(m)
if new:
    with open(seen_path, "w") as fh:
        fh.write("\n".join(sorted(seen)))
    with open(log_path, "a") as fh:
        for m in new:
            fh.write("%s NEW %s %s %s\n" % (m.get("ts"), m.get("id"), m.get("type"), m.get("subject")))
PYEOF
    sleep "$interval"
  done
}

if [ "${MUSE_BRIDGE_LIB_ONLY:-0}" = "1" ]; then
  # dung cho test: source file nay roi goi truc tiep cac ham
  return 0 2>/dev/null || exit 0
fi

case "${1:-}" in
  setup)   shift; cmd_setup "$@" ;;
  hello)   shift; bus send --type HELLO --subject "Muse da len" --body "$(hostname) $(date -Is)" ;;
  report)  shift; status_report ;;
  send)    shift; bus send "$@" ;;
  inbox)   shift; bus inbox "$@" ;;
  ack)     shift; bus ack "$@" ;;
  status)  shift; bus status "$@" ;;
  worker)  shift; cmd_worker "$@" ;;
  *) echo "usage: muse_side.sh {setup|hello|report|send|inbox|ack|status|worker}"; exit 2 ;;
esac
