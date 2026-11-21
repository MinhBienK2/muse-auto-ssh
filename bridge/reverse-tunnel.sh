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

write_unit_files() {
  # Sinh file unit systemd + ban template ben vung. MOT noi dung duy nhat cho
  # ca: muse_side.sh (setup) va hook (khoi phuc sau khi container refresh)
  # -> unit khong bao gio lech giua 2 noi dung.
  # Chi ghi lai khi NOI DUNG doi: hook goi "--write-unit" moi 15s -> ghi lai
  # lien tuc se doi mtime file + thoi doi "daemon-reload" lien tuc (nhieu hon
  # can thiet, va khoang cach giua "ghi file" va "daemon-reload" la khoang
  # thoi gian unit chua duoc load -> co so "unit inactive" that).
  local port="$1" loop="$2" log="$3" out="$4"
  local tmp="$out.new.$$"
  cat > "$tmp" <<EOF
[Unit]
Description=Muse reverse SSH tunnel (port $port) - may ngoai
After=network.target
# Tat hanh muc "start request repeated too quickly": mac dinh systemd bo qua
# unit sau 5 lan start trong 10s -> unit chuyen "failed" va KHONG tu len lai
# -> cell mat tunnel cho toi den khi hook chay lai.
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStartPre=/bin/bash -c "mkdir -p /run/sshd /var/run/sshd"
ExecStart=/bin/bash $loop
Restart=always
RestartSec=5
StandardOutput=append:$log
StandardError=append:$log

[Install]
WantedBy=multi-user.target
EOF
  if [ -f "$out" ] && cmp -s "$tmp" "$out"; then
    rm -f "$tmp"
    return 0
  fi
  mv -f "$tmp" "$out" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

CONFIG_FILE="$SCRIPT_DIR/tunnel-${PORT:-default}.conf"
[ -f "$CONFIG_FILE" ] || CONFIG_FILE="$SCRIPT_DIR/tunnel.conf"
# shellcheck source=/dev/null
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

# Thu muc chua file unit. Mac dinh la /etc/systemd/system; MUSE_UNIT_DIR de
# test offline (va de container khong co systemd) ghi ra sandbox.
UNIT_DIR="${MUSE_UNIT_DIR:-/etc/systemd/system}"

# Che do "--write-unit": sinh unit roi thoat (dung khi can tao lai file unit
# ma KHONG muốn chay loop - vd hook goi sau khi container bi refresh).
if [ "${1:-}" = "--write-unit" ]; then
  _loop="$SCRIPT_DIR/reverse-tunnel-${PORT:-2222}.sh"
  _log="${TUNNEL_LOG:-$SCRIPT_DIR/tunnel.log}"
  mkdir -p "$UNIT_DIR" 2>/dev/null || true
  write_unit_files "${PORT:-2222}" "$_loop" "$_log" \
    "$UNIT_DIR/muse-reverse-tunnel-${PORT:-2222}.service"
  write_unit_files "${PORT:-2222}" "$_loop" "$_log" \
    "$SCRIPT_DIR/muse-reverse-tunnel-${PORT:-2222}.service.template"
  chmod 644 "$UNIT_DIR/muse-reverse-tunnel-${PORT:-2222}.service" 2>/dev/null || true
  chmod 644 "$SCRIPT_DIR/muse-reverse-tunnel-${PORT:-2222}.service.template" 2>/dev/null || true
  exit 0
fi

# LOCAL_IP / LOCAL_USER / REMOTE_PORT deu den tu tunnel-<port>.conf (sinh boi may ngoai).
# Khong hard-code gia tri may cua mot nguoi cu the nao - may nao cung dung duoc.
: "${LOCAL_IP:?thieu LOCAL_IP trong $CONFIG_FILE}"
: "${LOCAL_USER:?thieu LOCAL_USER trong $CONFIG_FILE}"
REMOTE_PORT="${REMOTE_PORT:-2222}"
KEY_PATH="${KEY_PATH:-/home/hatch/.ssh/id_ed25519}"
PROXY_PATH="${PROXY_PATH:-$SCRIPT_DIR/ts-socat-proxy.sh}"
LOG="${TUNNEL_LOG:-$SCRIPT_DIR/tunnel.log}"
# sshd co the bi container xoa (openssh-server khong nam trong image) -> cho phep
# tro sang noi khac khi can (test cung dung bien nay).
SSHD_BIN="${SSHD_BIN:-/usr/sbin/sshd}"

LOOP_VERSION="v13"
log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

sshd_alive() {
  # sshd "chay" chua du - phai tra loi banner tren :22.
  # Dung python3: bash build co the TAT /dev/tcp (vd Ubuntu bash 5.3).
  # BAT pipe "| grep -q SSH": grep -q thoat ngay khi co ket qua -> pipe bi
  # dong -> helper nhan EPIPE. Capture TOAN BO output roi khop SAU khi helper
  # da thoat. (Helper doc het dong banner nen socket dong bang FIN, khong
  # RST -> sshd khong log "Connection reset by peer".)
  local banner
  banner="$(timeout 8 python3 "$SCRIPT_DIR/ts-connect-proxy.py" --banner 127.0.0.1 22 2>/dev/null || true)"
  case "$banner" in *SSH*) return 0 ;; esac
  return 1
}

in_unit_cgroup() {
  # Tien trinh co nam trong cgroup cua unit systemd khong?
  # Dung de biet "minh" co phai la supervisor chinh hay chi la ban sao.
  local unit="$1"
  local cg
  cg="$(cat /proc/$$/cgroup 2>/dev/null || true)"
  case "$cg" in *"$unit"*) return 0 ;; esac
  return 1
}

ensure_unit() {
  # systemd la supervisor CHINH cua tunnel. Ly do: hook runner cua Hatch la
  # tien trinh con cua agent session; platform pause session do -> hook + moi
  # tien trinh no spawn deu chet. Chi PID 1 (systemd) con song -> loop chay
  # DUOI systemd thi duoc khoi dong lai trong <= RestartSec giay, khong can
  # ai chat de "mo lai".
  [ -d /run/systemd/system ] || return 0
  command -v systemctl >/dev/null 2>&1 || return 0
  # Tat khi chay loop ngoai container (test offline): khong duoc touching
  # systemd cua may dang chay test.
  [ "${MUSE_LOOP_NO_SYSTEMD:-0}" = "1" ] && return 0
  local unit="muse-reverse-tunnel-${REMOTE_PORT}.service"
  local dst="$UNIT_DIR/$unit"
  # File unit do CHINH loop nay sinh (write_unit_files) -> luon dung ban moi
  # nhat, khong bao gio lam theo template cu.
  write_unit_files "$REMOTE_PORT" "$SCRIPT_DIR/reverse-tunnel-${REMOTE_PORT}.sh" \
    "$LOG" "$dst"
  write_unit_files "$REMOTE_PORT" "$SCRIPT_DIR/reverse-tunnel-${REMOTE_PORT}.sh" \
    "$LOG" "$SCRIPT_DIR/muse-reverse-tunnel-${REMOTE_PORT}.service.template"
  chmod 644 "$dst" 2>/dev/null || true
  mkdir -p "$UNIT_DIR" 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable "$unit" >/dev/null 2>&1 || true
  if systemctl is-active --quiet "$unit" 2>/dev/null; then
    # Unit dang chay. Neu CHINH TA khong phai process cua unit -> day la ban
    # sao -> thoat de khong tranh port "-R" voi supervisor chinh.
    if ! in_unit_cgroup "$unit"; then
      log "unit $unit da active (process khac) -> loop nay thoat, tranh 2 supervisor"
      exit 0
    fi
    return 0
  fi
  systemctl reset-failed "$unit" >/dev/null 2>&1 || true
  log "unit $unit khong active -> start"
  systemctl start "$unit" >/dev/null 2>&1 || true
  sleep 2
  if systemctl is-active --quiet "$unit" 2>/dev/null && ! in_unit_cgroup "$unit"; then
    log "unit $unit da len -> loop nay thoat, tranh 2 supervisor"
    exit 0
  fi
  return 0
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

ensure_sshd_config() {
  # Platform Hatch co the XOA hoac GHI DE /etc/ssh/sshd_config trong container.
  # sshd khong start duoc -> hook lap lai "sshd khong tra loi banner" -> platform danh
  # cell "sshd_config_invalid" + "sshd_banner_failed" -> flapping_backoff -> cell bi
  # refresh (mat mot vong). Ban config TOT nhat duoc giu o vung ben vung de khoi phuc.
  local cfg="/etc/ssh/sshd_config"
  local seed="/home/hatch/.muse-bridge/sshd_config"
  if [ -f "$cfg" ] && "$SSHD_BIN" -t >/dev/null 2>&1; then
    # config hop le -> luu ban tot vao vung ben vung (neu moi nhat hoac khac ban cu)
    if [ ! -f "$seed" ] || ! cmp -s "$cfg" "$seed"; then
      mkdir -p "$(dirname "$seed")" 2>/dev/null || true
      cp -f "$cfg" "$seed" 2>/dev/null || true
    fi
    return 0
  fi
  if [ -f "$seed" ]; then
    mkdir -p /etc/ssh 2>/dev/null || true
    cp -f "$seed" "$cfg" 2>/dev/null || true
    log "sshd_config khong hop le -> da khoi phuc tu seed ben vung"
    "$SSHD_BIN" -t >/dev/null 2>&1 && return 0
  fi
  # Het duong lui -> viet config toi thieu (sshd dang chet, giu config lai hon)
  mkdir -p /etc/ssh 2>/dev/null || true
  cat > "$cfg" <<'SSHD_CONFIG_EOF'
# Config toi thieu cho bridge - chi dung khi config cu khong hop le / bi xoa.
Port 22
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
StrictModes yes
X11Forwarding no
PrintMotd no
Subsystem sftp /usr/lib/openssh/sftp-server
SSHD_CONFIG_EOF
  mkdir -p "$(dirname "$seed")" 2>/dev/null || true
  cp -f "$cfg" "$seed" 2>/dev/null || true
  log "sshd_config khong hop le -> da viet config toi thieu moi"
}

sshd_out_of_unit_cgroup() {
  # sshd KHONG duoc o lai trong cgroup cua unit "muse-reverse-tunnel-<port>".
  # Ly do: unit do systemd restart -> systemd kill CA cgroup -> sshd master +
  # MOI phien SSH dang mo cung bi giet -> SSH mat ~15-20s, va lenh
  # (push/ghep/session cua nguoi dung) dang chay bi cut.
  # cgroup v2 (rw): chuyen sshd sang system.slice (ngoai unit) -> restart unit
  # khong con lay sshd theo.
  [ -w /sys/fs/cgroup/system.slice/cgroup.procs ] || return 0
  local pid cg
  for pid in $(pgrep -x sshd 2>/dev/null); do
    cg="$(awk -F: '/^0::/{print $3}' "/proc/$pid/cgroup" 2>/dev/null)"
    case "$cg" in
      ""|"/") continue ;;   # da o goc roi
    esac
    echo "$pid" > /sys/fs/cgroup/system.slice/cgroup.procs 2>/dev/null || true
  done
}

ensure_sshd() {
  # Container refresh -> /usr/sbin/sshd bi overlay xoa mat -> cai lai tu local deb
  if [ ! -x "$SSHD_BIN" ]; then
    log "sshd bi thieu -> tu cai lai tu deb cache..."
    local deb_dir="/home/hatch/.muse-bridge/deb"
    local apt_cache="/var/cache/apt/archives"
    if ls "$deb_dir"/openssh-server*.deb >/dev/null 2>&1; then
      dpkg -i "$deb_dir"/openssh-*.deb >/dev/null 2>&1 || true
    elif ls "$apt_cache"/openssh-server*.deb >/dev/null 2>&1; then
      dpkg -i "$apt_cache"/openssh-*.deb >/dev/null 2>&1 || true
    elif command -v apt-get >/dev/null 2>&1; then
      export http_proxy="http://hatch-egress-proxy:3130" https_proxy="http://hatch-egress-proxy:3130"
      export HTTP_PROXY="$http_proxy" HTTPS_PROXY="$https_proxy"
      timeout 30 apt-get install -y -qq --no-install-recommends openssh-server >/dev/null 2>&1 || true
    fi
  fi

  # /run/sshd phai ton tai voi quyen 0755 (tranh loi privilege separation directory)
  mkdir -p /run/sshd /var/run/sshd
  chmod 755 /run/sshd /var/run/sshd 2>/dev/null || true
  chown root:root /run/sshd /var/run/sshd 2>/dev/null || true

  # Khoi phuc SSH Host Keys neu /etc bi wipe
  local host_key_seed="/home/hatch/.muse-bridge/ssh_host"
  if [ -d "$host_key_seed" ] && ls "$host_key_seed"/ssh_host_* >/dev/null 2>&1; then
    mkdir -p /etc/ssh
    for hk in "$host_key_seed"/ssh_host_*; do
      [ -f "$hk" ] || continue
      local base_hk; base_hk="$(basename "$hk")"
      if [ ! -f "/etc/ssh/$base_hk" ]; then
        cp -f "$hk" "/etc/ssh/$base_hk" 2>/dev/null || true
      fi
    done
    chmod 600 /etc/ssh/ssh_host_*_key 2>/dev/null || true
    chmod 644 /etc/ssh/ssh_host_*_key.pub 2>/dev/null || true
  elif [ -f /etc/ssh/ssh_host_ed25519_key ]; then
    mkdir -p "$host_key_seed"
    cp -f /etc/ssh/ssh_host_* "$host_key_seed/" 2>/dev/null || true
    chmod 700 "$host_key_seed" 2>/dev/null || true
  fi

  ensure_sshd_config

  if [ -x "$SSHD_BIN" ]; then
    if ! pgrep -x sshd >/dev/null 2>&1; then
      "$SSHD_BIN" 2>/dev/null || true
      sleep 1
    fi
    # 2 lan that lien nhau moi restart sshd: 1 lan that co the chi la "cell
    # dang chay nhe" -> pkill sshd giua chung -> tunnel chop chop.
    local miss=0 attempt
    for attempt in 1 2; do
      if sshd_alive; then miss=0; break; fi
      miss=$((miss + 1))
      [ "$attempt" = "1" ] && sleep 2
    done
    if [ "$miss" -ge 2 ]; then
      log "sshd khong tra loi banner 2 lan lien nhau -> restart"
      pkill -x sshd >/dev/null 2>&1 || true
      sleep 1
      "$SSHD_BIN" 2>/dev/null || true
      sleep 2
      sshd_alive && log "sshd da khoi dong lai" || log "sshd van khong phan hoi"
    fi
    # sshd ra khoi cgroup unit (xem sshd_out_of_unit_cgroup) -> restart unit
    # khong lam sshd (va phien SSH dang mo) chet theo.
    sshd_out_of_unit_cgroup
  fi
}

log "loop start -> ${LOCAL_USER}@${LOCAL_IP}:${REMOTE_PORT} (key $KEY_PATH)"

# --- tu keo ban moi tu may ngoai (huong container -> local qua proxy) ----------
# Huong nay LUON hoat dong (key cua container da duoc may ngoai authorize),
# nen container tu cai lai duoc du may ngoai khong vao duoc container.
pull_updates() {
  local base="/home/hatch/.muse-bridge"
  local bundle="$base/bundle"
  local tmp="$base/.pull.$$"
  # MOT lan ket noi: tai ca bundle bang mot tar stream.
  # Truoc day 6 lan ssh (~4s moi lan qua proxy) -> 25s; container hay bi giet
  # vong lap giua chung -> bundle KHONG BAO GI chuyen vao container.
  rm -rf "$tmp"; mkdir -p "$tmp"
  if ! timeout 90 ssh -n -o "ProxyCommand=${PROXY_PATH} %h %p" -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=15 \
        -i "$KEY_PATH" "${LOCAL_USER}@${LOCAL_IP}" \
        'cd ~/.muse-bridge/bundle && tar cf - VERSION bridge.py muse_side.sh inject_watchdog.py reverse-tunnel.sh ts-socat-proxy.sh ts-connect-proxy.py deb 2>/dev/null' \
        2>/dev/null | tar xf - -C "$tmp" 2>/dev/null; then
    rm -rf "$tmp"; return 0
  fi
  if [ ! -f "$tmp/VERSION" ]; then rm -rf "$tmp"; return 0; fi
  local ver
  ver="$(tr -d '\r' < "$tmp/VERSION")"
  [ -n "$ver" ] || { rm -rf "$tmp"; return 0; }
  [ "$ver" = "$(cat "$base/.version" 2>/dev/null)" ] && { rm -rf "$tmp"; return 0; }
  mkdir -p "$bundle"
  local f
  local hook="/home/hatch/hooks/scripts/muse-platform-boot.sh"
  for f in VERSION bridge.py muse_side.sh inject_watchdog.py reverse-tunnel.sh ts-socat-proxy.sh ts-connect-proxy.py; do
    [ -f "$tmp/$f" ] || continue
    mv -f "$tmp/$f" "$bundle/$f"; chmod 700 "$bundle/$f" 2>/dev/null || true
  done
  if [ -d "$tmp/deb" ]; then
    mkdir -p "$base/deb"
    cp -rf "$tmp/deb"/* "$base/deb/" 2>/dev/null || true
  fi
  rm -rf "$tmp"
  cp -f "$bundle/bridge.py" "$base/bridge.py" 2>/dev/null || true
  # inject_watchdog.py MOI phai duoc dung de re-inject hook. Ban trước goi
  # "$base/inject_watchdog.py" (ban CUU) -> ban moi ve bundle khong bao gio
  # duoc dung -> sua loi trong injector khong lan xuong container.
  cp -f "$bundle/inject_watchdog.py" "$base/inject_watchdog.py" 2>/dev/null || true
  # Tu cap nhat script loop dang chay (per-port) tu bundle: container khong
  # can may ngoai SSH vao duoc de nhan code moi. Ghi file .new roi mv (atomic)
  # de khong lam hong bash dang chay script (bash doc file theo offset).
  local self="$SCRIPT_DIR/reverse-tunnel-${REMOTE_PORT}.sh"
  if [ -f "$bundle/reverse-tunnel.sh" ] && [ -f "$self" ] && ! cmp -s "$bundle/reverse-tunnel.sh" "$self"; then
    cp -f "$bundle/reverse-tunnel.sh" "$self.new" 2>/dev/null && mv -f "$self.new" "$self" 2>/dev/null \
      && chmod 700 "$self" 2>/dev/null \
      && log "da tu cap nhat script loop tu bundle -> khoi dong lai vong lap"
    # exec (thay the process, giu nguyen PID) de CODE MOI co hieu luc ngay,
    # khong phai doi hook chay. Hook cua Hatch co the mat 45 phut -> loop phai
    # tu cap nhat duoc ma khong can ai "day bundle" bang tay.
    exec /bin/bash "$self"
  fi
  # Proxy helper cung tu cap nhat: duong truc tiep truoc, HTTP CONNECT proxy sau.
  if [ -f "$bundle/ts-socat-proxy.sh" ] && [ -d "$SCRIPT_DIR" ] \
     && ! cmp -s "$bundle/ts-socat-proxy.sh" "$SCRIPT_DIR/ts-socat-proxy.sh"; then
    cp -f "$bundle/ts-socat-proxy.sh" "$SCRIPT_DIR/ts-socat-proxy.sh.new" 2>/dev/null \
      && mv -f "$SCRIPT_DIR/ts-socat-proxy.sh.new" "$SCRIPT_DIR/ts-socat-proxy.sh" 2>/dev/null \
      && chmod 700 "$SCRIPT_DIR/ts-socat-proxy.sh" 2>/dev/null \
      && log "da tu cap nhat proxy helper tu bundle"
  fi
  # Helper python di kem (duong cuu khi container thieu socat).
  if [ -f "$bundle/ts-connect-proxy.py" ] && [ -d "$SCRIPT_DIR" ] \
     && ! cmp -s "$bundle/ts-connect-proxy.py" "$SCRIPT_DIR/ts-connect-proxy.py"; then
    cp -f "$bundle/ts-connect-proxy.py" "$SCRIPT_DIR/ts-connect-proxy.py.new" 2>/dev/null \
      && mv -f "$SCRIPT_DIR/ts-connect-proxy.py.new" "$SCRIPT_DIR/ts-connect-proxy.py" 2>/dev/null \
      && chmod 700 "$SCRIPT_DIR/ts-connect-proxy.py" 2>/dev/null \
      && log "da tu cap nhat proxy helper python tu bundle"
  fi
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
# Ban giao quyen giam sat cho systemd (neu co). Neu unit chay roi, loop nay
# (ban chay ngoai, do hook spawn) thoat de khong tranh port "-R".
ensure_unit

tunnel_alive() {
  # KHONG khop "ssh -N -R ...": thu tu flag co the khac nhau
  # (vi du "ssh -i KEY -N -R ..." cua script khac) -> pattern do bo qua het
  # ssh dang chay, watchdog spawn them va giu chet port forward.
  # Khop theo "-R <port>:" de khong phu thuoc thu tu flag.
  pgrep -f -- "-R ${REMOTE_PORT}:127.0.0.1:22" >/dev/null 2>&1
}

start_tunnel() {
  # ssh chay NEN: vong lap van tick de check sshd + authorized_keys + tunnel.
  # Neu chay foreground, sshd chi duoc kiem tra luc tunnel vua rot -> container
  # mat sshd ma van co 1 session treo thi SSH tu ngoai vao khong bao gio len.
  nohup ssh -N -R "${REMOTE_PORT}:127.0.0.1:22" \
    -o "ProxyCommand=${PROXY_PATH} %h %p" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 \
    -o ConnectTimeout=15 \
    -i "$KEY_PATH" "${LOCAL_USER}@${LOCAL_IP}" >> "$LOG" 2>&1 &
  log "tunnel (re)start pid=$! port=$REMOTE_PORT"
}

PULL_EVERY=5
PULL_N=0
# Backoff khi tunnel chet lien tuc (may ngoai/proxy down): mo lai moi 15s se
# lam may nhe + nhay log. Tang dan thoi gian cho, toi da 60s.
TUNNEL_FAILS=0
while true; do
  ensure_authorized_keys
  ensure_sshd
  if ! tunnel_alive; then
    TUNNEL_FAILS=$((TUNNEL_FAILS + 1))
    start_tunnel
    sleep 5
    if [ "$TUNNEL_FAILS" -ge 3 ]; then
      sleep 25
    fi
  else
    TUNNEL_FAILS=0
  fi
  PULL_N=$((PULL_N + 1))
  if [ "$PULL_N" -ge "$PULL_EVERY" ]; then
    PULL_N=0
    pull_updates || true
  fi
  sleep 10
done
