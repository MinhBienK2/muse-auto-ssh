#!/bin/bash
# ==============================================================================
# health_probe.sh - chay TRONG container Muse, in 1 dong JSON ve suc khoe.
#
# Container Muse do platform refresh (xoay vong, xoa moi "/" overlay + /tmp
# tmpfs). CHI /home/hatch (150G, /dev/mapper/rv) moi ben vung. Script nay do
# dung thu can theo doi:
#   - boot_id doi   = container da restart (doi vong doi)
#   - uptime_s      = thoi gian song tinh tu lan boot gan nhat
#   - spool counts  = so tin bus (inbox/outbox/pending/read) - ben vung
#   - sshd/tunnel   = kenh SSH con dung khong
#
# Usage (qua SSH):  bash -s -- <port>
# Output: 1 dong JSON. KHONG duoc in them - phia local parse tung dong.
# ==============================================================================
set -uo pipefail

port="${1:-}"

num() {  # $1 = gia tri raw -> so nguyen (0 neu khong phai so)
  case "${1:-}" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$1" ;;
  esac
}

count_json() {  # $1 = thu muc -> so file .json
  local n
  n="$(ls "$1"/*.json 2>/dev/null | wc -l | tr -d ' ')"
  num "$n"
}

boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"
uptime_s="$(cut -d' ' -f1 /proc/uptime 2>/dev/null || echo 0)"
uptime_s="$(num "${uptime_s%%.*}")"

mem_kb="$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)"
mem_available_mb=$(( $(num "$mem_kb") / 1024 ))

disk_free_mb="$(df -Pm / 2>/dev/null | awk 'NR==2 {print $4}')"
disk_free_mb="$(num "$disk_free_mb")"

# Thu ben vung: thu muc khac filesystem "/" + ghi duoc.
durable=""
for d in /home/hatch /persistent /data; do
  if [ -d "$d" ] && touch "$d/.health_probe" 2>/dev/null; then
    rm -f "$d/.health_probe"
    durable="$d"
    break
  fi
done

spool="/root/.muse-bridge"
p_inbox="$(count_json "$spool/inbox")"
p_outbox="$(count_json "$spool/outbox")"
p_pending="$(count_json "$spool/pending")"
p_read="$(count_json "$spool/read")"

sshd_state="stopped"
pgrep -x sshd >/dev/null 2>&1 && sshd_state="running"

tunnel=0
if [ -n "$port" ]; then
  tunnel="$(pgrep -f "ssh -N -R $port:" 2>/dev/null | wc -l | tr -d ' ')"
  tunnel="$(num "$tunnel")"
fi

printf '{"boot_id":"%s","uptime_s":%s,"mem_available_mb":%s,"disk_free_mb":%s,"durable":"%s","home":"%s","peer_inbox":%s,"peer_outbox":%s,"peer_pending":%s,"peer_read":%s,"sshd":"%s","tunnel":%s}\n' \
  "$boot_id" "$uptime_s" "$mem_available_mb" "$disk_free_mb" "$durable" "$HOME" \
  "$p_inbox" "$p_outbox" "$p_pending" "$p_read" "$sshd_state" "$tunnel"
