#!/bin/bash
# ==============================================================================
# local_side.sh - Phia may cua nguoi dung (Agent Ngoai). Ho tro NHIEU Muse host.
#
#   arm       --host <id>   chuan bi moi truong + config + push bundle
#   hosts                   danh sach cac Muse host da dang ky
#   add-host  --host <id>   dang ky mot Muse host moi (port, alias, spool)
#   status    --host <id>   trang thai kenh cua host
#   inbox     --host <id>   doc tin nhan
#   send      --host <id>   gui tin nhan
#   ack       --host <id>   danh dau da xu ly
#   sync      --host <id>   gui lai tin pending
#   daemon    --host <id>   watcher inbox
#   prompt    --host <id>   render MUSE_PROMPT.md cho host do
#   push      --host <id>   day bundle moi len host do
#   onboard   --host <id>   \x{1}trong suot: dang ky -> gui prompt qua web Muse -> xac nhan
#   authorize  --host <id>  them public key cua Muse vao authorized_keys
#
# Idempotent: chay lai nhieu lan khong sao.
# Thong tin ket noi tung host duoc luu trong repo (thu muc .muse-hosts/, KHONG push len git).
# ==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BRIDGE_PY="$SCRIPT_DIR/bridge.py"
MUSE_WEB="$SCRIPT_DIR/muse_web.py"
STATE_DIR="${MUSE_BRIDGE_STATE:-$HOME/.muse-bridge}"
HOSTS_DIR="$STATE_DIR/hosts"
SPOOLS_DIR="$STATE_DIR/spools"
REPO_HOSTS_DIR="${MUSE_BRIDGE_REPO_HOSTS:-$REPO_DIR/.muse-hosts}"
LOCAL_KEY="${LOCAL_KEY:-$HOME/.ssh/id_ed25519}"
REMOTE_SPOOL="${REMOTE_SPOOL:-/root/.muse-bridge}"
MUSE_URL="${MUSE_URL:-https://muse.ai/}"

say()  { echo "[bridge] $*"; }
warn() { echo "[bridge][WARN] $*" >&2; }
die()  { echo "[bridge][ERROR] $*" >&2; exit 1; }

HOST=""
PORT=""
LABEL=""
KEY=""
WAIT_TIMEOUT="${WAIT_TIMEOUT:-600}"

parse_flags() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --host)    HOST="$2"; shift 2 ;;
      --port)    PORT="$2"; shift 2 ;;
      --label)   LABEL="$2"; shift 2 ;;
      --key)     KEY="$2"; shift 2 ;;
      --timeout) WAIT_TIMEOUT="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
}

host_config() { echo "$HOSTS_DIR/$1.json"; }
host_card()   { echo "$REPO_HOSTS_DIR/$1.json"; }

# ------------------------------------------------------------------ ssh helpers
ssh_host() {
  local port="$1"; shift
  ssh -p "$port" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o BatchMode=yes \
      -o ConnectTimeout=15 \
      -o LogLevel=ERROR \
      -i "$LOCAL_KEY" root@127.0.0.1 "$@" < /dev/null
}

ssh_host_push() {
  local port="$1" file="$2"; shift 2
  ssh -p "$port" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o BatchMode=yes \
      -o ConnectTimeout=15 \
      -o LogLevel=ERROR \
      -i "$LOCAL_KEY" root@127.0.0.1 "$@" < "$file"
}

host_reachable() { ssh_host "$1" 'true' >/dev/null 2>&1; }

# ------------------------------------------------------------------ host registry
host_ids() {
  [ -d "$HOSTS_DIR" ] || return 0
  find "$HOSTS_DIR" -maxdepth 1 -name '*.json' -printf '%f\n' 2>/dev/null | sed 's/\.json$//' | sort
}

host_field() {
  local id="$1" key="$2"
  python3 - "$(host_config "$id")" "$key" <<'PY'
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))
except Exception:
    print("")
    raise SystemExit(0)
print(cfg.get(sys.argv[2], "") if len(sys.argv) > 2 else "")
PY
}

card_field() {
  local id="$1" key="$2"
  python3 - "$(host_card "$id")" "$key" <<'PY'
import json, sys
try:
    card = json.load(open(sys.argv[1]))
except Exception:
    print("")
    raise SystemExit(0)
print(card.get(sys.argv[2], "") if len(sys.argv) > 2 else "")
PY
}

host_peer_port() {
  python3 - "$(host_config "$1")" <<'PY'
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))
except Exception:
    print("")
    raise SystemExit(0)
print(cfg.get("peer", {}).get("port", ""))
PY
}

host_local_spool() {
  python3 - "$(host_config "$1")" <<'PY'
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))
except Exception:
    print("")
    raise SystemExit(0)
print(cfg.get("spool", ""))
PY
}

default_host() {
  local marker="$STATE_DIR/default-host"
  if [ -f "$marker" ]; then cat "$marker"; return; fi
  local ids; ids="$(host_ids)"
  local count; count="$(echo "$ids" | grep -c . || true)"
  if [ "$count" = "1" ]; then echo "$ids"; return; fi
  echo ""
}

require_host() {
  [ -n "$HOST" ] || HOST="$(default_host)"
  [ -n "$HOST" ] || die "chua co Muse host nao. Dung: bash scripts/bridge.sh add-host --host <id>"
  [ -f "$(host_config "$HOST")" ] || die "khong tim thay host '$HOST' (file: $(host_config "$HOST"))"
}

next_free_port() {
  local p=2222
  while ss -tln 2>/dev/null | grep -q ":$p\b"; do p=$((p+1)); done
  echo "$p"
}

write_ssh_alias() {
  local id="$1" port="$2"
  local cfg="$HOME/.ssh/config"
  mkdir -p "$HOME/.ssh"; touch "$cfg"; chmod 600 "$cfg"
  if grep -q "^Host $id\$" "$cfg" 2>/dev/null; then
    python3 - "$cfg" "$id" "$port" <<'PY'
import re, sys
path, host, port = sys.argv[1:4]
text = open(path).read()
block = re.compile(r"(?ms)^Host %s\n.*?(?=^Host |\Z)" % re.escape(host))
new = "Host %s\n    HostName 127.0.0.1\n    Port %s\n    User root\n    IdentityFile ~/.ssh/id_ed25519\n    StrictHostKeyChecking no\n    UserKnownHostsFile /dev/null\n    LogLevel ERROR\n" % (host, port)
text = block.sub(new, text, count=1)
open(path, "w").write(text)
PY
  else
    cat >> "$cfg" <<EOF

# Muse Reverse SSH Tunnel - $id
Host $id
    HostName 127.0.0.1
    Port $port
    User root
    IdentityFile ~/.ssh/id_ed25519
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
EOF
  fi
}

add_host() {
  local id="$1"
  local port="${2:-}"
  [ -n "$id" ] || die "add-host can --host <id>"
  [ -n "$port" ] || port="$(next_free_port)"
  mkdir -p "$HOSTS_DIR" "$SPOOLS_DIR" "$REPO_HOSTS_DIR" "$(dirname "$(host_card "$id")")"

  local local_spool="$SPOOLS_DIR/$id"
  mkdir -p "$local_spool"/{inbox,outbox,pending,read,logs}

  cat > "$(host_config "$id")" <<EOF
{
  "id": "$id",
  "role": "local",
  "spool": "$local_spool",
  "peer": {
    "id": "$id",
    "role": "muse",
    "transport": "ssh",
    "host": "127.0.0.1",
    "port": $port,
    "user": "root",
    "spool": "$REMOTE_SPOOL",
    "ssh_opts": ["-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "LogLevel=ERROR", "-i", "$LOCAL_KEY"]
  }
}
EOF

  cat > "$(host_card "$id")" <<EOF
{
  "id": "$id",
  "label": "${LABEL:-Muse $id}",
  "tunnel_port": $port,
  "ssh_alias": "$id",
  "created": "$(date -Is)",
  "local_spool": "$local_spool",
  "muse_spool": "$REMOTE_SPOOL",
  "muse_url": "$MUSE_URL",
  "state": "registered"
}
EOF

  write_ssh_alias "$id" "$port"
  if [ ! -f "$STATE_DIR/default-host" ]; then echo "$id" > "$STATE_DIR/default-host"; fi
  say "da dang ky host '$id': port=$port alias=$id spool=$local_spool"
  say "the tin rao repo (khong push): $(host_card "$id")"
}


# ------------------------------------------------------------------ provision Muse
muse_provision() {
  local port="$1"
  local ts_ip="$2"
  local spool="$3"
  host_reachable "$port" || { warn "host o port $port chua truy cap duoc"; return 1; }

  say "day bus + bundle len container..."
  ssh_host "$port" "mkdir -p /root/.muse-bridge/{inbox,outbox,pending,read,logs} /root/.muse-bridge/bundle /root/.ssh && chmod 700 /root/.muse-bridge /root/.ssh" >/dev/null 2>&1 || true
  ssh_host_push "$port" "$BRIDGE_PY" "cat > /root/.muse-bridge/bridge.py" || true
  ssh_host_push "$port" "$SCRIPT_DIR/muse_side.sh" "cat > /root/.muse-bridge/muse_side.sh" || true
  ssh_host_push "$port" "$SCRIPT_DIR/inject_watchdog.py" "cat > /root/.muse-bridge/inject_watchdog.py" || true
  ssh_host "$port" "chmod 700 /root/.muse-bridge /root/.muse-bridge/bridge.py /root/.muse-bridge/muse_side.sh /root/.muse-bridge/inject_watchdog.py; chmod 600 /root/.muse-bridge/bridge.py" >/dev/null 2>&1 || true

  # chay setup phia Muse (sshd, loop tunnel, watchdog, config bus, HELLO/REPORT)
  say "chay setup phia container..."
  ssh_host "$port" "bash /root/.muse-bridge/muse_side.sh setup --local-host $ts_ip --local-user $(id -un) --local-pubkey '$(awk '{print $1" "$2}' "${LOCAL_KEY}.pub")' --local-spool $spool --local-port $port" 2>&1 | tail -25
  say "setup xong; neu HELLO/REPORT chua den, chay 'bridge.sh sync --host $HOST' de gui lai"
}

# ------------------------------------------------------------------ arm
detect_ts_ip() {
  local ip
  if command -v tailscale >/dev/null 2>&1; then
    ip="$(tailscale ip -4 2>/dev/null | head -n1)"
  fi
  [ -n "$ip" ] || ip="$(ip -brief addr show tailscale0 2>/dev/null | awk '{print $3}' | cut -d/ -f1)"
  echo "$ip"
}

ensure_sshd() {
  if ss -tln 2>/dev/null | grep -q ':22\b'; then
    say "sshd: listening on :22"
    return 0
  fi
  say "sshd: not listening on :22 -> trying to start"
  sudo -n systemctl enable --now ssh >/dev/null 2>&1 || sudo -n systemctl enable --now sshd >/dev/null 2>&1 || true
  ss -tln 2>/dev/null | grep -q ':22\b' || warn "sshd chua len duoc. Chay: sudo systemctl enable --now ssh"
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

install_authorizer() {
  install -m 700 "$SCRIPT_DIR/authorize_peer.sh" "$STATE_DIR/authorize_peer.sh"
  touch "$STATE_DIR/tofu.enabled"
  chmod 600 "$STATE_DIR/tofu.enabled"
}

install_sshd_hook() {
  local installer="$REPO_DIR/scripts/install_tofu_hook.sh"
  if ! command -v sshd >/dev/null 2>&1 && [ ! -x /usr/sbin/sshd ]; then
    warn "khong tim thay sshd -> bo qua TOFU hook"; return 1
  fi
  if ! sudo -n true 2>/dev/null; then
    warn "TOFU hook can quyen root. Chay 1 lan: sudo bash $installer"
    return 1
  fi
  sudo -n bash "$installer" && say "TOFU hook: da cai" || warn "cai TOFU hook that bai"
}

install_bundle_local() {
  mkdir -p "$STATE_DIR/bundle"
  install -m 0755 "$BRIDGE_PY" "$STATE_DIR/bridge.py"
  install -m 0755 "$SCRIPT_DIR/muse_side.sh" "$STATE_DIR/bundle/muse_side.sh"
  install -m 0755 "$SCRIPT_DIR/muse_web.py" "$STATE_DIR/bundle/muse_web.py"
  install -m 0755 "$SCRIPT_DIR/inject_watchdog.py" "$STATE_DIR/bundle/inject_watchdog.py"
}

push_bundle() {
  local port="$1"
  host_reachable "$port" || { warn "khong ket noi duoc host tren port $port -> skip push bundle"; return 1; }
  ssh_host "$port" "mkdir -p $REMOTE_SPOOL/bundle /root/.ssh && chmod 700 /root/.ssh" >/dev/null 2>&1 || true
  ssh_host_push "$port" "$BRIDGE_PY" "cat > $REMOTE_SPOOL/bridge.py" || { warn "push bridge.py that bai"; return 1; }
  ssh_host_push "$port" "$SCRIPT_DIR/muse_side.sh" "cat > $REMOTE_SPOOL/muse_side.sh" || { warn "push muse_side.sh that bai"; return 1; }
  ssh_host_push "$port" "$SCRIPT_DIR/inject_watchdog.py" "cat > $REMOTE_SPOOL/inject_watchdog.py" || true
  ssh_host_push "$port" "$SCRIPT_DIR/muse_side.sh" "cat > $REMOTE_SPOOL/bundle/muse_side.sh" || true
  ssh_host_push "$port" "$SCRIPT_DIR/inject_watchdog.py" "cat > $REMOTE_SPOOL/bundle/inject_watchdog.py" || true
  ssh_host "$port" "chmod 700 $REMOTE_SPOOL $REMOTE_SPOOL/bridge.py $REMOTE_SPOOL/muse_side.sh $REMOTE_SPOOL/inject_watchdog.py; chmod 600 $REMOTE_SPOOL/bridge.py" >/dev/null 2>&1 || true
  say "bundle da duoc day len host (port $port)"
}

cmd_arm() {
  parse_flags "$@"
  require_host
  say "=== ARM host '$HOST' ==="
  local port; port="$(host_peer_port "$HOST")"
  say "tailscale ip: $(detect_ts_ip) | port: $port"
  ensure_sshd
  ensure_key
  install_bundle_local
  install_authorizer
  install_sshd_hook
  push_bundle "$port" || true
  cmd_status
}

# ------------------------------------------------------------------ bus wrappers
bus_py() { python3 "$STATE_DIR/bridge.py" --host "$HOST" "$@"; }

cmd_status() {
  parse_flags "$@"
  require_host
  bus_py status "$@"
}

cmd_inbox() {
  parse_flags "$@"
  require_host
  bus_py inbox "$@"
}

cmd_send() {
  parse_flags "$@"
  require_host
  bus_py send "$@"
}

cmd_ack() {
  parse_flags "$@"
  require_host
  bus_py ack "$@"
}

cmd_sync() {
  parse_flags "$@"
  require_host
  bus_py sync "$@"
}

cmd_daemon() {
  parse_flags "$@"
  require_host
  local interval="${1:-3}"
  mkdir -p "$STATE_DIR/logs"
  local log="$STATE_DIR/logs/inbox-$HOST.log"
  say "daemon: watching spool cua host '$HOST' (Ctrl-C de dung)"
  ( while true; do
      bus_py sync >>"$log" 2>&1 || true
      sleep 10
    done ) &
  SYNC_PID=$!
  trap '[ -n "${SYNC_PID:-}" ] && kill "$SYNC_PID" 2>/dev/null' EXIT INT TERM
  bus_py inbox --watch --interval "$interval" 2>/dev/null | while IFS= read -r line; do
    [ -z "$line" ] && continue
    printf '%s %s\n' "$(date -Is)" "$line" >> "$log"
    case "$line" in
      *type=QUESTION*|*type=TASK*)
        command -v notify-send >/dev/null 2>&1 && \
          notify-send "muse-bridge[$HOST]" "$(printf '%s' "$line" | head -c 200)" 2>/dev/null || true
        ;;
    esac
  done
}

cmd_push() {
  parse_flags "$@"
  require_host
  push_bundle "$(host_peer_port "$HOST")"
}

cmd_prompt() {
  parse_flags "$@"
  require_host
  local port; port="$(host_peer_port "$HOST")"
  local spool; spool="$(host_local_spool "$HOST")"
  local out="$REPO_HOSTS_DIR/$HOST/MUSE_PROMPT.md"
  mkdir -p "$(dirname "$out")"
  python3 "$REPO_DIR/scripts/render_prompt.py" \
    --host "$(detect_ts_ip)" --port "$port" --spool "$spool" --out "$out" || die "render prompt that bai"
  say "prompt: $out"
  [ "${1:-}" = "--print" ] && cat "$out"
  return 0
}

cmd_hosts() {
  parse_flags "$@"
  printf '%-12s %-6s %-10s %-12s %s\n' ID PORT ALIAS SPOOL STATE
  local ids; ids="$(host_ids)"
  [ -z "$ids" ] && { echo "(chua co host nao)"; return 0; }
  for id in $ids; do
    local port state
    port="$(host_peer_port "$id")"
    state="$(card_field "$id" "state")"
    printf '%-12s %-6s %-10s %-12s %s\n' "$id" "$port" "$id" "$(host_local_spool "$id")" "${state:-unknown}"
  done
}

cmd_authorize() {
  parse_flags "$@"
  local key="$KEY"
  [ -n "$key" ] || die "usage: authorize --host <id> --key '<ssh-ed25519 ...>'"
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  touch "$HOME/.ssh/authorized_keys"; chmod 600 "$HOME/.ssh/authorized_keys"
  if grep -qxF "$key" "$HOME/.ssh/authorized_keys"; then
    say "key da co san trong authorized_keys"
  else
    echo "$key" >> "$HOME/.ssh/authorized_keys"
    say "da them key vao authorized_keys"
  fi
}

# ------------------------------------------------------------------ onboard
muse_web_send() {  # $1 = file, $2 = thread (rong = tao chat moi), $3 = wait regex
  local file="$1" thread="$2" wait="$3"
  local args=(send --file "$file" --url "$MUSE_URL" --wait-for "$wait" --timeout "$WAIT_TIMEOUT")
  [ -n "$thread" ] && args+=(--thread "$thread")
  [ -n "$thread" ] || args+=(--new-chat)
  python3 "$MUSE_WEB" "${args[@]}" 2>&1
}

cmd_onboard() {
  require_host
  local port; port="$(host_peer_port "$HOST")"
  local spool; spool="$(host_local_spool "$HOST")"
  local ts_ip; ts_ip="$(detect_ts_ip)"
  local dir="$REPO_HOSTS_DIR/$HOST"
  local prompt_file="$dir/MUSE_PROMPT.md"
  local reply_file="$dir/reply.txt"
  local thread=""

  say "=== ONBOARD host '$HOST' (port $port) ==="
  ensure_sshd
  ensure_key
  install_bundle_local
  install_authorizer
  install_sshd_hook
  cmd_prompt >/dev/null
  say "prompt da render: $prompt_file"

  # --- 1) gui prompt vao web Muse -----------------------------------------
  say "gui prompt vao web Muse ($MUSE_URL) ..."
  local out; out="$(muse_web_send "$prompt_file" "" "DIRECT_OK|trong suốt|tunnel|cổng")"
  echo "$out" > "$dir/web.log"
  thread="$(echo "$out" | grep -oE 'THREAD_URL=https://[^ ]+' | head -1 | cut -d= -f2-)"
  say "thread: ${thread:-unknown}"

  # --- 2) vong lap doi thoai: authorize key / tra loi / cho tunnel ---------
  local i
  for i in $(seq 1 8); do
    if host_reachable "$port"; then
      say "KET NOI DUOC (port $port)"
      break
    fi
    python3 "$MUSE_WEB" reply --wait-for "DIRECT_OK|trong suốt|tunnel|cổng|không|lỗi" \
      --timeout 90 > "$reply_file" 2>&1 || true

    # neu reply chua public key cua Muse -> authorize o may ngoai
    local muse_key
    muse_key="$(grep -oE 'ssh-ed25519 [A-Za-z0-9+/=]+' "$reply_file" 2>/dev/null | head -1 || true)"
    local local_key; local_key="$(awk '{print $1" "$2}' "${LOCAL_KEY}.pub")"
    if [ -n "$muse_key" ] && [ "$muse_key" != "$local_key" ]; then
      say "reply co public key cua Muse -> authorize o may ngoai"
      cmd_authorize --key "$muse_key"
    fi

    # gui yeu cau tiep theo cho agent
    local follow="$dir/follow.txt"
    if grep -qi "permission denied" "$reply_file" 2>/dev/null; then
      say "agent bao Permission denied -> da authorize, nho thu lai"
      printf '%s\n' "Máy tôi đã authorize public key của bạn trong authorized_keys. Bạn thử lại bước SSH từ container sang máy tôi (100.120.205.53) và báo tôi kết quả; nếu thông thì mở reverse tunnel cổng $port như đã nói." > "$follow"
    elif grep -qiE "cho tôi biết|cần gì|bạn muốn tôi làm gì|hỏi" "$reply_file" 2>/dev/null; then
      say "agent hoi them -> tra loi theo cac buoc da gui"
      printf '%s\n' "Cứ làm tiếp theo đúng các bước tôi đã nói ở trên (bước 1, 2, 3, 4), mỗi bước một lệnh ngắn. Nếu bước nào lỗi thì dừng và báo tôi nguyên văn lỗi." > "$follow"
    else
      break
    fi
    say "gui tin nhan tiep theo cho agent ..."
    out="$(muse_web_send "$follow" "$thread" "DIRECT_OK|trong suốt|tunnel|cổng")"
    echo "$out" >> "$dir/web.log"
  done

  # --- 3) provision bus + watchdog len container --------------------------
  if host_reachable "$port"; then
    muse_provision "$port" "$ts_ip" "$spool"
    bus_py sync >/dev/null 2>&1 || true
    cmd_status
  else
    warn "chua thac ket noi duoc host tren port $port (xem $dir/web.log)"
  fi

  python3 "$REPO_DIR/scripts/update_host_state.py" "$(host_card "$HOST")" "$port"
}

# ------------------------------------------------------------------ dispatch
case "${1:-}" in
  arm)       shift; cmd_arm "$@" ;;
  status)    shift; cmd_status "$@" ;;
  inbox)     shift; cmd_inbox "$@" ;;
  send)      shift; cmd_send "$@" ;;
  ack)       shift; cmd_ack "$@" ;;
  sync)      shift; cmd_sync "$@" ;;
  daemon)    shift; cmd_daemon "$@" ;;
  prompt)    shift; cmd_prompt "$@" ;;
  push)      shift; cmd_push "$@" ;;
  hosts)     shift; cmd_hosts "$@" ;;
  add-host)  shift; parse_flags "$@"; add_host "$HOST" "$PORT" ;;
  authorize) shift; cmd_authorize "$@" ;;
  onboard)   shift; cmd_onboard "$@" ;;
  *) echo "usage: local_side.sh {arm|status|inbox|send|ack|sync|daemon|prompt|push|hosts|add-host|authorize|onboard}"; exit 2 ;;
esac
