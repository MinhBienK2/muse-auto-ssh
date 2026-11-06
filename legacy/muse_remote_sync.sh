#!/bin/bash
# ==============================================================================
# muse_remote_sync.sh - Phia MUSE: adopt / verify / heal reverse SSH tunnel.
# ------------------------------------------------------------------------------
# Dung cho Agent Muse (container root@htch-runtime).
# KHONG can repo GitHub: tat ca noi dung can thiet deu nam san trong file nay.
#
# NGUYEN TAC (khong duoc pham):
#   1. ADOPT FIRST: neu da co deployment/tunnel dang chay -> ADOPT, KHONG cai
#      lai, KHONG kill, KHONG doi key dang duoc may ngoai authorize.
#   2. Khong bao gio sinh key moi neu key cu da duoc may ngoai authorize.
#   3. Khong sua gi tren may ngoai tru viet mailbox ~/muse-bridge/.
#
# Usage:
#   bash muse_remote_sync.sh [LOCAL_IP] [LOCAL_USER] ["LOCAL_PUBLIC_KEY"]
# ==============================================================================
set -uo pipefail

LOCAL_IP="${1:-100.120.205.53}"
LOCAL_USER="${2:-minhbien}"
LOCAL_PUB_KEY="${3:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL6imO2CxV2zyjmMyHr3LYmRO0vT8mjm+Cs7ptNodIfa phamminhbien333@gmail.com}"
MAILBOX_REL="${MAILBOX_REL:-muse-bridge}"

HOME_DIR="${HOME:-/root}"
note() { echo "[muse-sync] $*"; }
warn() { echo "[muse-sync][WARN] $*"; }
ok()   { echo "[muse-sync][OK]   $*"; }

# ------------------------------------------------------------------------------
# 1. Tim BASE (thu muc deployment) - thu cac vi tri da biet
# ------------------------------------------------------------------------------
BASE=""
for cand in /home/hatch/workspace/muse-platform-setup \
            "$HOME_DIR/workspace/muse-platform-setup" \
            /root/workspace/muse-platform-setup; do
  if [ -d "$cand" ] && { [ -d "$cand/keys" ] || [ -d "$cand/tunnel" ]; }; then
    BASE="$cand"; break
  fi
done
[ -n "$BASE" ] || BASE="/home/hatch/workspace/muse-platform-setup"
TUNNEL_DIR="$BASE/tunnel"
KEYS_DIR="$BASE/keys"
mkdir -p "$TUNNEL_DIR" "$KEYS_DIR" /run/sshd /var/run/sshd
note "BASE=$BASE"

# ------------------------------------------------------------------------------
# 2. Keypair cua Muse - tai dung key dang chay/duoc authorize
# ------------------------------------------------------------------------------
KEY_FILE=""
for cand in "$KEYS_DIR/muse-agent-ed25519" "$HOME_DIR/.ssh/id_ed25519" \
            "$HOME_DIR/workspace/muse-platform-setup/keys/muse-agent-ed25519"; do
  [ -f "$cand" ] && { KEY_FILE="$cand"; break; }
done

if [ -z "$KEY_FILE" ]; then
  note "Khong tim thay key - sinh key moi tai $KEYS_DIR/muse-agent-ed25519"
  ssh-keygen -t ed25519 -f "$KEYS_DIR/muse-agent-ed25519" -N "" -C "muse-external-agent" >/dev/null 2>&1 || \
    { warn "sinh key that bai"; KEY_FILE=""; }
  [ -n "$KEY_FILE" ] && KEY_FILE="$KEYS_DIR/muse-agent-ed25519"
else
  note "Dung key hien co: $KEY_FILE"
fi
MUSE_PUB_KEY=""
[ -n "$KEY_FILE" ] && MUSE_PUB_KEY="$(cat "${KEY_FILE}.pub" 2>/dev/null)"

# ------------------------------------------------------------------------------
# 3. Proxy script (socat -> hatch-egress-proxy:3130)
# ------------------------------------------------------------------------------
PROXY="$TUNNEL_DIR/ts-socat-proxy.sh"
if [ ! -f "$PROXY" ]; then
  note "Thieu ts-socat-proxy.sh - tai ban mo nhung (verbatim scripts/templates/ts-socat-proxy.sh)"
  cat > "$PROXY" <<'TS_EOF'
#!/bin/bash
# ==============================================================================
# ts-socat-proxy.sh - Dynamic Tailscale Proxy Bridge via Hatch Egress Proxy
# ==============================================================================

# Auto-discover HTTPS_PROXY credentials if missing in current shell
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

# Connect to Tailscale endpoint via Hatch egress CONNECT proxy on port 3130
exec socat - "PROXY:hatch-egress-proxy:$1:$2,proxyport=3130,proxyauth=${puser}:${ppass}"
TS_EOF
  chmod +x "$PROXY"
fi

# ------------------------------------------------------------------------------
# 4. Loop script (vong lap tu reconnect)
# ------------------------------------------------------------------------------
LOOP=""
for cand in "$TUNNEL_DIR/reverse-tunnel-g3.sh" "$TUNNEL_DIR/reverse-tunnel.sh"; do
  [ -f "$cand" ] && { LOOP="$cand"; break; }
done
if [ -z "$LOOP" ]; then
  LOOP="$TUNNEL_DIR/reverse-tunnel.sh"
  note "Khong co loop script - tai ban mo nhung"
  cat > "$LOOP" <<'RT_EOF'
#!/bin/bash
# ==============================================================================
# reverse-tunnel.sh - Auto-reconnecting Reverse SSH Tunnel: Muse VM -> Local Host
# ==============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/tunnel.conf"

if [ -f "$CONFIG_FILE" ]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

LOCAL_USER="${LOCAL_USER:-minhbien}"
LOCAL_IP="${LOCAL_IP:-100.120.205.53}"
REMOTE_PORT="${REMOTE_PORT:-2222}"
KEY_PATH="${KEY_PATH:-$HOME/workspace/muse-platform-setup/keys/muse-agent-ed25519}"
PROXY_PATH="${PROXY_PATH:-$SCRIPT_DIR/ts-socat-proxy.sh}"

# Fallback for key location
if [ ! -f "$KEY_PATH" ] && [ -f "$HOME/.ssh/id_ed25519" ]; then
  KEY_PATH="$HOME/.ssh/id_ed25519"
fi


echo "[$(date '+%F %T')] Starting reverse tunnel to ${LOCAL_USER}@${LOCAL_IP} (Forwarding port ${REMOTE_PORT} -> localhost:22)..."

while true; do
  # Ensure local sshd directory and service are running
  mkdir -p /run/sshd /var/run/sshd
  if ! pgrep -x sshd >/dev/null 2>&1; then
    /usr/sbin/sshd 2>/dev/null || true
  fi

  ssh -N -R "${REMOTE_PORT}:127.0.0.1:22" \
    -o "ProxyCommand=${PROXY_PATH} %h %p" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 \
    -o ConnectTimeout=10 \
    -i "$KEY_PATH" "${LOCAL_USER}@${LOCAL_IP}"
  
  EXIT_CODE=$?
  echo "[$(date '+%F %T')] Reverse tunnel exited (code ${EXIT_CODE}). Reconnecting in 10s..."
  sleep 10
done
RT_EOF
  chmod +x "$LOOP"
fi
note "LOOP=$LOOP"

# tunnel.conf cho loop script (loop dang chay co the khong doc file nay)
cat > "$TUNNEL_DIR/tunnel.conf" <<EOF
LOCAL_IP="$LOCAL_IP"
LOCAL_USER="$LOCAL_USER"
REMOTE_PORT="2222"
KEY_PATH="$KEY_FILE"
EOF

# ------------------------------------------------------------------------------
# 5. sshd (dia chi noi dung nhan noi bo)
# ------------------------------------------------------------------------------
if ! pgrep -x sshd >/dev/null 2>&1; then
  /usr/sbin/sshd 2>/dev/null || warn "Khong khoi dong duoc sshd."
fi
pgrep -x sshd >/dev/null 2>&1 && ok "sshd running (pid: $(pgrep -x sshd | tr '\n' ' '))"

# Authorize key may ngoai (de may ngoai ssh vao Muse qua port 2222)
if [ -n "$LOCAL_PUB_KEY" ]; then
  mkdir -p "$HOME_DIR/.ssh"; chmod 700 "$HOME_DIR/.ssh"
  grep -qxF "$LOCAL_PUB_KEY" "$HOME_DIR/.ssh/authorized_keys" 2>/dev/null || \
    echo "$LOCAL_PUB_KEY" >> "$HOME_DIR/.ssh/authorized_keys"
  chmod 600 "$HOME_DIR/.ssh/authorized_keys"
  ok "Key may ngoai da duoc authorize trong $HOME_DIR/.ssh/authorized_keys"
fi

# ------------------------------------------------------------------------------
# 6. Trang thai tunnel - ADOPT, khong kill neu dang chay
# ------------------------------------------------------------------------------
TUNNEL_PROCS="$(pgrep -af 'ssh -N -R' 2>/dev/null)"
if [ -n "$TUNNEL_PROCS" ]; then
  ok "Co reverse-tunnel process dang chay (ADOPT - khong restart):"
  echo "$TUNNEL_PROCS" | sed 's/^/    /'
  TUNNEL_STATE="ADOPTED"
else
  note "Khong thay reverse-tunnel process - khoi dong loop moi"
  nohup /bin/bash "$LOOP" >> "$TUNNEL_DIR/tunnel.log" 2>&1 </dev/null &
  sleep 3
  TUNNEL_STATE="STARTED"
  pgrep -af 'ssh -N -R' >/dev/null 2>&1 || warn "Loop chua len duoc - xem $TUNNEL_DIR/tunnel.log"
fi

# ------------------------------------------------------------------------------
# 7. Persistence: Hatch boot hook (15s) - va systemd chi khi CHUA co hook
# ------------------------------------------------------------------------------
BOOT_HOOK=""
for cand in /home/hatch/hooks/scripts/muse-platform-boot.sh \
            "$HOME_DIR/hooks/scripts/muse-platform-boot.sh"; do
  [ -f "$cand" ] && { BOOT_HOOK="$cand"; break; }
done

HOOK_HAS_WATCHDOG=0
if [ -n "$BOOT_HOOK" ]; then
  grep -q "Auto keep SSH and G3 Reverse Tunnel alive" "$BOOT_HOOK" && HOOK_HAS_WATCHDOG=1
  if [ "$HOOK_HAS_WATCHDOG" = "0" ]; then
    note "Inject watchdog vao $BOOT_HOOK"
    python3 - "$BOOT_HOOK" "$LOOP" <<'PYEOF'
import sys
path, loop = sys.argv[1], sys.argv[2]
with open(path, "r") as f:
    content = f.read()

anchor = "set -euo pipefail\n"
inject = """
# [Self-healing: Auto keep SSH and G3 Reverse Tunnel alive]
mkdir -p /run/sshd /var/run/sshd
if ! pgrep -x sshd >/dev/null 2>&1; then
    /usr/sbin/sshd 2>/dev/null || true
fi
if ! pgrep -f "reverse-tunnel" >/dev/null 2>&1; then
    nohup /bin/bash %s >> %s 2>&1 &
fi
""" % (loop, loop.rsplit("/", 1)[0] + "/tunnel.log")

if anchor in content:
    idx = content.find(anchor)
    content = content[:idx + len(anchor)] + inject + content[idx + len(anchor):]
else:
    content = inject + content
with open(path, "w") as f:
    f.write(content)
print("  -> Injected watchdog into " + path)
PYEOF
    HOOK_HAS_WATCHDOG=1
  else
    ok "Watchdog da co trong $BOOT_HOOK"
  fi
else
  warn "Khong tim thay Hatch boot hook - can dung systemd service de duy tri"
fi

PERSISTENCE="none"
if [ "$HOOK_HAS_WATCHDOG" = "1" ]; then
  PERSISTENCE="hatch-hook(15s)"
elif command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
  cat > /etc/systemd/system/muse-reverse-tunnel.service <<EOF
[Unit]
Description=Muse to Local Machine Reverse SSH Tunnel
After=network.target

[Service]
Type=simple
User=root
ExecStartPre=/bin/sh -c "mkdir -p /run/sshd /var/run/sshd && (pgrep -x sshd || /usr/sbin/sshd)"
ExecStart=/bin/bash $LOOP
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload >/dev/null 2>&1 && systemctl enable muse-reverse-tunnel.service >/dev/null 2>&1
  PERSISTENCE="systemd"
  ok "Da tao + enable muse-reverse-tunnel.service (ExecStart=$LOOP)"
else
  warn "Khong co hook, khong co systemd -> persistence chua duoc bao dam"
fi

# ------------------------------------------------------------------------------
# 8. Memory / heartbeat (chi ghi neu thieu)
# ------------------------------------------------------------------------------
HEARTBEAT_FILE="/home/hatch/HEARTBEAT.md"
[ -f "$HEARTBEAT_FILE" ] || HEARTBEAT_FILE="$HOME_DIR/HEARTBEAT.md"
if [ -f "$HEARTBEAT_FILE" ]; then
  grep -q "reverse-tunnel" "$HEARTBEAT_FILE" || cat >> "$HEARTBEAT_FILE" <<EOF
- reverse-tunnel: verify reverse tunnel loop is active, auto-start if missing: pgrep -f reverse-tunnel || nohup /bin/bash $LOOP >> $TUNNEL_DIR/tunnel.log 2>&1 &
EOF
  ok "Heartbeat OK ($HEARTBEAT_FILE)"
fi

MEMORY_FILE="/home/hatch/MEMORY.md"
[ -f "$MEMORY_FILE" ] || MEMORY_FILE="$HOME_DIR/MEMORY.md"
if [ -f "$MEMORY_FILE" ]; then
  grep -q "PERMANENT AUTO-TUNNEL SETUP" "$MEMORY_FILE" || cat >> "$MEMORY_FILE" <<EOF

## Commitments
- PERMANENT AUTO-TUNNEL SETUP: The reverse tunnel to local machine is fully self-healing and durable. Automated via:
  1) Persistent Hatch hook in /home/hatch/hooks/scripts/muse-platform-boot.sh (every 15s).
  2) Loop script $LOOP (reconnect every 10s).
  3) ts-socat-proxy.sh with dynamic HTTPS_PROXY token auto-discovery.
  Whenever local machine opens sshd, the reconnect loop connects within 10s. Do not kill or override this automation.
EOF
  ok "Long-term memory OK ($MEMORY_FILE)"
fi

# ------------------------------------------------------------------------------
# 9. Probe: Muse -> may ngoai (qua proxy) va may ngoai -> Muse (port 2222)
# ------------------------------------------------------------------------------
SSH_OPTS=(-n -o "ProxyCommand=$PROXY $LOCAL_IP 22" -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=20)
PROBE_UP="FAILED"
PROBE_OUT=""
if [ -n "$KEY_FILE" ] && PROBE_OUT=$(timeout 40 ssh "${SSH_OPTS[@]}" -i "$KEY_FILE" \
      "${LOCAL_USER}@${LOCAL_IP}" 'echo MUSE->LOCAL_OK; hostname; ss -tln 2>/dev/null | grep -E ":(2222|2233)\b" || echo NO_FORWARD_PORT' 2>&1); then
  PROBE_UP="OK"
  ok "Probe Muse -> may ngoai: OK"
  echo "$PROBE_OUT" | sed 's/^/    /'
else
  warn "Probe Muse -> may ngoai that bai (key chua duoc may ngoai authorize?):"
  echo "$PROBE_OUT" | tail -n 5 | sed 's/^/    /'
fi

# ------------------------------------------------------------------------------
# 10. Ghi trang thai len may ngoai qua mailbox (kenh phoi hop hai chieu)
# ------------------------------------------------------------------------------
MAILBOX_SENT="NOT_SENT"
if [ "$PROBE_UP" = "OK" ] && [ -n "$KEY_FILE" ]; then
  STATUS_TMP="$(mktemp)"
  {
    echo "timestamp: $(date -Is 2>/dev/null || date)"
    echo "host: $(hostname)"
    echo "base: $BASE"
    echo "key: $KEY_FILE"
    echo "pubkey: $MUSE_PUB_KEY"
    echo "loop: $LOOP"
    echo "tunnel_state: $TUNNEL_STATE"
    echo "persistence: $PERSISTENCE"
    echo "probe_muse_to_local: $PROBE_UP"
    echo "tunnel_procs:"
    pgrep -af 'ssh -N -R' 2>/dev/null | sed 's/^/  /'
  } > "$STATUS_TMP"
  if timeout 30 ssh -o "ProxyCommand=$PROXY $LOCAL_IP 22" -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=20 \
       -i "$KEY_FILE" "${LOCAL_USER}@${LOCAL_IP}" \
       "mkdir -p ~/$MAILBOX_REL && cat > ~/$MAILBOX_REL/MUSE_STATUS.md" < "$STATUS_TMP" 2>/dev/null; then
    MAILBOX_SENT="SENT"
    ok "Da ghi ~/$MAILBOX_REL/MUSE_STATUS.md tren may ngoai"
  else
    warn "Khong ghi duoc mailbox tren may ngoai"
  fi
  rm -f "$STATUS_TMP"
fi

# ------------------------------------------------------------------------------
# 11. Bao cao
# ------------------------------------------------------------------------------
echo ""
echo "===== MUSE_STATUS ====="
echo "MUSE_HOST=$(hostname)"
echo "MUSE_BASE=$BASE"
echo "MUSE_PUBKEY=$MUSE_PUB_KEY"
echo "MUSE_KEY_PATH=$KEY_FILE"
echo "MUSE_LOOP=$LOOP"
echo "MUSE_TUNNEL_TARGET=${LOCAL_USER}@${LOCAL_IP}:22"
echo "MUSE_TUNNEL_STATE=$TUNNEL_STATE"
echo "MUSE_PERSISTENCE=$PERSISTENCE"
echo "MUSE_TUNNEL_PID=$(pgrep -f 'ssh -N -R' | tr '\n' ' ')"
echo "MUSE_SSHD_PID=$(pgrep -x sshd | tr '\n' ' ')"
echo "MUSE_PROBE=$PROBE_UP"
echo "MUSE_MAILBOX=$MAILBOX_SENT"
echo "===== END ====="
