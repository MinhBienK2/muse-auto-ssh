#!/bin/bash
# ==============================================================================
# install_sshd_keepalive.sh - Cfg sshd tren may ngoai de tu dong tha session treo
# (can root, chay 1 lan).
#
#   sudo bash scripts/install_sshd_keepalive.sh
#
# VAI SAO CAN:
#   Reverse tunnel cua container Muse la mot SESSION ssh mo o may ngoai. Khi
#   container bi platform "freeze" (dong bang) hoac bi xoa, phi TCP cua session
#   do van con treo tren may ngoai -> sshd giu port forward (2222/2223) va
#   container moi se khong bind duoc ("remote port forwarding failed") -> SSH
#   tu ngoai vao khong bao gio len du tunnel cu cua container da chet.
#
#   ClientAliveInterval + ClientAliveCountMax cho phep sshd tu dong dong session
#   khong con phan hoi (session treo) -> port forward duoc nha ra -> container
#   moi bind duoc ngay.
#
# KHONG ANH HUONG: session dang binh thuong (co keepalive) thi khong bi dong.
# ==============================================================================
set -euo pipefail

CONF="/etc/ssh/sshd_config.d/98-muse-bridge-keepalive.conf"

if [ "$(id -u)" != "0" ]; then
  echo "can quyen root: sudo bash $0" >&2
  exit 1
fi

BACKUP=""
if [ -f "$CONF" ]; then
  BACKUP="$CONF.bak.$(date +%s)"
  cp "$CONF" "$BACKUP"
fi

cat > "$CONF" <<'EOF'
# muse-bridge: dong session ssh treo (container Muse bi freeze/xoa) de nha
# port forward 2222/2223, container moi bind lai duoc.
ClientAliveInterval 30
ClientAliveCountMax 3
EOF
chmod 644 "$CONF"

if ! /usr/sbin/sshd -t; then
  echo "sshd -t that bai -> khoi phuc config cu" >&2
  if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
    cp "$BACKUP" "$CONF"
    echo "da khoi phuc $CONF tu $BACKUP" >&2
  else
    echo "KHONG co backup de khoi phuc - sua $CONF bang tay" >&2
  fi
  exit 1
fi

systemctl reload ssh 2>/dev/null || systemctl restart ssh 2>/dev/null || service ssh reload
echo "sshd keepalive da cai: $CONF"
echo "Session treo se bi dong sau toi da 90s -> port forward 2222/2223 duoc nha ra."
