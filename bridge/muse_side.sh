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
export MUSE_BRIDGE_STATE="$STATE_DIR"
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
              /home/hatch/.ssh/id_ed25519 /home/hatch/.ssh/id_ed25519_nopass \
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
  local src="$SCRIPT_DIR/ts-socat-proxy.sh"
  if [ ! -f "$src" ]; then
    warn "khong tim thay $src - bo qua cap nhat proxy"
    return 0
  fi
  local tmp="$PROXY.tmp.$$"
  install -m 0755 "$src" "$tmp"
  if [ -f "$PROXY" ] && cmp -s "$tmp" "$PROXY"; then
    rm -f "$tmp"
    say "proxy script: $PROXY (da co, dung phien ban)"
  else
    mv -f "$tmp" "$PROXY"
    say "proxy script: $PROXY (da cap nhat)"
  fi
}

ensure_loop() {
  # Loop rieng cho tung port: reverse-tunnel-<port>.sh (nhieu Muse host tren cung may)
  local target="$BASE/tunnel/reverse-tunnel-$LOCAL_PORT.sh"
  local src="$SCRIPT_DIR/reverse-tunnel.sh"
  mkdir -p "$(dirname "$target")"
  if [ ! -f "$src" ]; then
    warn "khong tim thay $src - dung loop script co san"
    [ -f "$target" ] && LOOP="$target"
    return 0
  fi
  local tmp="$target.tmp.$$"
  install -m 0755 "$src" "$tmp"
  if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
    say "loop script: $target (da co, dung phien ban)"
  else
    mv -f "$tmp" "$target"
    say "loop script: $target (da cap nhat)"
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
  # luu seed ben vung de container tu khoi phuc sau khi refresh
  mkdir -p "/home/hatch/.muse-bridge"
  grep -qxF "$LOCAL_PUBKEY" "/home/hatch/.muse-bridge/authorized_keys.seed" 2>/dev/null || \
    echo "$LOCAL_PUBKEY" >> "/home/hatch/.muse-bridge/authorized_keys.seed"
  chmod 600 "/home/hatch/.muse-bridge/authorized_keys.seed" 2>/dev/null || true
  say "da authorize key may ngoai trong $HOME/.ssh/authorized_keys"
}

write_tunnel_conf() {
  # Config RIENG theo port: moi reverse-tunnel-<port>.sh doc tunnel-<port>.conf.
  # (dung 1 file tunnel.conf chung se lam 2 port tren cung container dau nhau)
  mkdir -p "$BASE/tunnel"
  cat > "$BASE/tunnel/tunnel-$LOCAL_PORT.conf" <<EOF
LOCAL_IP="$LOCAL_HOST"
LOCAL_USER="$LOCAL_USER"
REMOTE_PORT="$LOCAL_PORT"
KEY_PATH="$KEY"
PROXY_PATH="$PROXY"
EOF
}

ensure_tunnel() {
  write_tunnel_conf
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

ensure_systemd_unit() {
  # systemd la supervisor CHINH cho tunnel (Hatch hook chi giam sat).
  command -v systemctl >/dev/null 2>&1 || return 1
  # is-system-running tra exit != 0 khi system "degraded" -> dung /run/systemd/system de kiem tra
  [ -d /run/systemd/system ] || return 1
  local unit="/etc/systemd/system/muse-reverse-tunnel-$LOCAL_PORT.service"
  local tmp="$unit.tmp.$$"
  cat > "$tmp" <<EOF
[Unit]
Description=Muse reverse SSH tunnel (port $LOCAL_PORT) - may ngoai
After=network.target

[Service]
Type=simple
ExecStartPre=/bin/bash -c "mkdir -p /run/sshd /var/run/sshd"
ExecStart=/bin/bash $LOOP
Restart=always
RestartSec=10
StandardOutput=append:$BASE/tunnel/tunnel.log
StandardError=append:$BASE/tunnel/tunnel.log

[Install]
WantedBy=multi-user.target
EOF
  if [ -f "$unit" ] && cmp -s "$tmp" "$unit"; then
    rm -f "$tmp"
  else
    mv -f "$tmp" "$unit"
  fi
  # luu template o vung BEN VUNG (/home/hatch) de watchdog tu cai lai sau khi refresh
  local tpl="$BASE/tunnel/muse-reverse-tunnel-$LOCAL_PORT.service.template"
  if ! cmp -s "$unit" "$tpl"; then
    cp -f "$unit" "$tpl" 2>/dev/null || true
  fi
  systemctl daemon-reload >/dev/null 2>&1
  systemctl enable "muse-reverse-tunnel-$LOCAL_PORT.service" >/dev/null 2>&1
  # CHI MOT supervisor: stop service -> tat moi loop cu -> start lai service
  systemctl stop "muse-reverse-tunnel-$LOCAL_PORT.service" >/dev/null 2>&1 || true
  # don dep unit generic cu (neu co) de khong tranh cong.
  # Unit generic + unit per-port cung chay 1 tunnel -> 2 supervisor tranh
  # cung port "-R" -> "remote port forwarding failed" -> vong lap reconnect.
  if systemctl list-unit-files 2>/dev/null | grep -q "^muse-reverse-tunnel.service"; then
    systemctl disable --now muse-reverse-tunnel.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/muse-reverse-tunnel.service
    systemctl daemon-reload >/dev/null 2>&1
  fi
  pkill -f "[r]everse-tunnel-${LOCAL_PORT}.sh" >/dev/null 2>&1 || true
  pkill -f "[s]sh -N -R ${LOCAL_PORT}:" >/dev/null 2>&1 || true
  sleep 1
  systemctl start "muse-reverse-tunnel-$LOCAL_PORT.service" >/dev/null 2>&1
  sleep 3
  if systemctl is-active --quiet "muse-reverse-tunnel-$LOCAL_PORT.service"; then
    say "systemd unit: muse-reverse-tunnel-$LOCAL_PORT.service active+enabled (supervisor chinh)"
  else
    warn "systemd unit khong len duoc - xem $BASE/tunnel/tunnel.log"
  fi
  return 0
}

ensure_persistent_layout() {
  # Container refresh -> /root (overlay) bi xoa; /home/hatch (btrfs) moi ben vung.
  # => bus nam o /home/hatch (symlink OK, khong phai duong dan sshd).
  # => authorized_keys: KHONG symlink sang /home/hatch (dir do group-writable ->
  #    sshd StrictModes se TU CHOI key). Dung SEED file + COPY lai vao /root/.ssh.
  local persistent="/home/hatch/.muse-bridge"
  mkdir -p "$persistent" /home/hatch/.ssh
  if [ ! -L "$STATE_DIR" ] && [ -d "$STATE_DIR" ] && [ "$STATE_DIR" != "$persistent" ]; then
    cp -a "$STATE_DIR"/. "$persistent"/ 2>/dev/null || true
    rm -rf "$STATE_DIR"
    ln -sfn "$persistent" "$STATE_DIR"
    say "bus chuyen sang vung ben vung: $persistent (symlink $STATE_DIR)"
  elif [ ! -e "$STATE_DIR" ]; then
    mkdir -p "$persistent"
    ln -sfn "$persistent" "$STATE_DIR"
  fi

  # --- authorized_keys: seed ben vung + copy vao /root/.ssh -------------------
  local seed="$persistent/authorized_keys.seed"
  local ak="/root/.ssh/authorized_keys"
  mkdir -p /root/.ssh; chmod 700 /root/.ssh
  if [ -L "$ak" ]; then
    # symlink cu -> thay bang file that (StrictModes)
    rm -f "$ak"
  fi
  if [ -f "$ak" ]; then
    cp -f "$ak" "$seed" 2>/dev/null || true
    chmod 600 "$seed" 2>/dev/null || true
  elif [ -f "$seed" ]; then
    cp -f "$seed" "$ak" 2>/dev/null || true
    chmod 600 "$ak" 2>/dev/null || true
    say "da khoi phuc authorized_keys tu seed ben vung"
  fi
}

ensure_hatch_hook() {
  # Hatch CHAY hook theo definition JSON trong /home/hatch/hooks/definitions/.
  # Script co trong /home/hatch/hooks/scripts/ ma KHONG co definition => KHONG BAO GIO chay.
  local defs="/home/hatch/hooks/definitions"
  local def="$defs/muse-platform-boot.json"
  mkdir -p "$defs" /home/hatch/hooks/scripts
  if [ -f "$def" ]; then
    say "hatch hook definition: da co ($def)"
    return 0
  fi
  local now_ms
  now_ms=$(($(date +%s) * 1000))
  cat > "$def" <<EOF
{
  "version": 1,
  "id": "muse-platform-boot",
  "enabled": true,
  "script_path": "~/hooks/scripts/muse-platform-boot.sh",
  "poll_interval_secs": 15,
  "script_timeout_secs": 60,
  "delivery": { "surface": "main" },
  "presentation_locale": "en-US",
  "prompt": "Pure-script boot/self-heal hook for muse-platform. Always exits silently; never wakes an LLM worker.",
  "created_at_ms": $now_ms,
  "updated_at_ms": $now_ms
}
EOF
  say "hatch hook definition: da tao moi ($def)"
}

ensure_persistence() {
  local hook
  hook=""
  for cand in /home/hatch/hooks/scripts/muse-platform-boot.sh \
              "$HOME/hooks/scripts/muse-platform-boot.sh"; do
    [ -f "$cand" ] && { hook="$cand"; break; }
  done
  if [ -z "$hook" ]; then
    # container moi: tao script + DANG KY hook (khong co definition thi khong chay)
    hook="/home/hatch/hooks/scripts/muse-platform-boot.sh"
    if [ ! -f "$hook" ]; then
      cat > "$hook" <<'HOOK_EOF'
#!/usr/bin/env bash
# muse-platform-boot.sh - boot/self-heal hook (muse-bridge)
# Script nao duoc Hatch GOI bang definition trong /home/hatch/hooks/definitions/.
# Phai ket thuc bang HATCH_HOOK_RESULT decision=silent de KHONG day agent LLM.
set -euo pipefail
HOOK_EOF
      chmod +x "$hook"
    fi
    ensure_hatch_hook
    warn "da tao hook moi + dang ky definition"
  fi
  ensure_hatch_hook
  # Gate theo PHIEN BAN watchdog, khong phoi chuoi "watchdog ok":
  # hook dang co ban cu se bi skip neu chi kiem tra chuoi chung -> khong bao gio len v6.
  if grep -q "muse-bridge watchdog v6" "$hook"; then
    PERSISTENCE="hatch-hook(15s)"
    say "watchdog: da co ban moi nhat trong $hook"
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
  ensure_persistent_layout
  ensure_tunnel
  ensure_persistence
  ensure_systemd_unit || true
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
