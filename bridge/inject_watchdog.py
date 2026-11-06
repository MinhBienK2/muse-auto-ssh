#!/usr/bin/env python3
"""Inject (or upgrade) the muse-bridge watchdog into the Hatch boot hook.

Usage:
    python3 inject_watchdog.py <hook.sh> <loop.sh> <key> <proxy.sh> <user> <host>

Idempotent:
  - moi block watchdog cu (v1/v2/v3) deu bi go, chi con block v4.
  - block v4 inject lai deu an toan (thay bang chinh no).

v4 sua 3 loi cu gay CHET kenh:
  - supervisor phai theo PORT (unit per-port + pgrep theo port), tranh 2 host
    tren cung container du vao chung 1 supervisor -> "remote port forwarding
    failed for listen port <port>" -> vong lap reconnect lien tuc.
  - systemd duoc detect bang /run/systemd/system, khong dung
    `systemctl is-system-running` (tra exit != 0 khi system "degraded",
    lam watchdog tu chay loop chung voi unit -> 2 supervisor).
  - block watchdog cu (v1/v2/v3) bi xoa sach, tranh hook va unit cung kick
    nhau 2 lan.
"""

from __future__ import annotations

import os
import re
import sys

BEGIN = "# [muse-bridge watchdog v4] BEGIN"
END = "# [muse-bridge watchdog v4] END"

BLOCK = """
# [muse-bridge watchdog v4] BEGIN
mkdir -p /run/sshd /var/run/sshd
# 0) container refresh -> /root/.ssh/authorized_keys mat -> khoi phuc tu vung BEN VUNG
mkdir -p /root/.ssh
SEED="/home/hatch/.muse-bridge/authorized_keys.seed"
if [ -L /root/.ssh/authorized_keys ]; then rm -f /root/.ssh/authorized_keys; fi
if [ ! -f /root/.ssh/authorized_keys ] && [ -f "$SEED" ]; then
    cp -f "$SEED" /root/.ssh/authorized_keys 2>/dev/null || true
    chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true
fi
# 1) sshd phai TRA LOI duoc banner tren :22 (pgrep khong du - sshd treo van bi bo qua)
if ! timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/22; head -c 4 <&3' 2>/dev/null | grep -q SSH; then
    pkill -x sshd >/dev/null 2>&1 || true
    sleep 1
    /usr/sbin/sshd >/dev/null 2>&1 || true
fi
# 2) dam bao co DUNG MOT supervisor cho port %(port)s:
#    - co systemd -> unit per-port la chinh, hook chi kick no
#    - khong co systemd -> hook tu chay loop
UNIT="muse-reverse-tunnel-%(port)s.service"
TPL="%(tpl)s"
if [ -d /run/systemd/system ]; then
    # container refresh -> /etc bi xoa: cai lai unit tu template BEN VUNG
    if [ -f "$TPL" ] && [ ! -f "/etc/systemd/system/$UNIT" ]; then
        cp -f "$TPL" "/etc/systemd/system/$UNIT" 2>/dev/null || true
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable "$UNIT" >/dev/null 2>&1 || true
    fi
    if [ -f "/etc/systemd/system/$UNIT" ]; then
        systemctl is-active --quiet "$UNIT" 2>/dev/null || \\
            systemctl start "$UNIT" >/dev/null 2>&1 || true
    fi
fi
# 3) script loop da duoc nang cap (version khac) -> restart de dung code moi
WANT="$(grep -o 'LOOP_VERSION="[^"]*"' "%(loop)s" 2>/dev/null | head -1)"
HAVE="$(cat "$(dirname "%(log)s")/.loop_version" 2>/dev/null | head -1)"
if [ -n "$WANT" ] && [ "$WANT" != "$HAVE" ]; then
    pkill -f "[b]ash %(loop)s" >/dev/null 2>&1 || true
    pkill -f "[s]sh -N -R %(port)s:" >/dev/null 2>&1 || true
    sleep 1
    HAVE=""
fi
if ! pgrep -f 'ssh -N -R %(port)s:' >/dev/null 2>&1; then
    if ! systemctl is-active --quiet "$UNIT" 2>/dev/null; then
        nohup /bin/bash %(loop)s >> %(log)s >/dev/null 2>&1 &
    fi
fi
# [muse-bridge watchdog v4] END
"""

# Moi block watchdog cu deu phai bi go - chi con duy nhat block v4.
OLD_BLOCK_PATTERNS = (
    r"\n?# \[Self-healing: Auto keep SSH and G3 Reverse Tunnel alive\].*?reverse-tunnel.*?\nfi\n",
    r"\n?# \[muse-bridge watchdog v\d+\] BEGIN.*?# \[muse-bridge watchdog v\d+\] END\n",
    r"\n?silent \"muse-bridge watchdog ok\"\n",
)


def port_from_loop(loop: str) -> str:
    """reverse-tunnel-2222.sh -> 2222 (fallback 2222)."""
    m = re.search(r"reverse-tunnel-(\d+)\.sh$", os.path.basename(loop))
    return m.group(1) if m else "2222"


def main(argv: list) -> int:
    if len(argv) != 7:
        print(__doc__)
        return 2
    hook, loop, key, proxy, user, host = argv[1:7]
    if not os.path.isfile(hook):
        print("inject_watchdog: khong tim thay %s" % hook, file=sys.stderr)
        return 1

    with open(hook, "r", encoding="utf-8") as fh:
        content = fh.read()

    for pat in OLD_BLOCK_PATTERNS:
        content = re.sub(pat, "", content, flags=re.S)

    log = loop.rsplit("/", 1)[0] + "/tunnel.log"
    inject = BLOCK % {
        "loop": loop,
        "log": log,
        "port": port_from_loop(loop),
        "tpl": loop.rsplit("/", 1)[0] + "/muse-reverse-tunnel-%s.service.template" % port_from_loop(loop),
        "key": key,
        "proxy": proxy,
        "user": user,
        "host": host,
    }

    # block phai khong duoc lam script hook "fail" (set -e) va phai ket thuc silent
    body = inject.rstrip("\n") + "\nsilent \"muse-bridge watchdog ok\"\n"
    anchor = "set -euo pipefail\n"
    if anchor in content:
        i = content.find(anchor)
        content = content[: i + len(anchor)] + body + content[i + len(anchor) :]
    else:
        content = body + content

    with open(hook, "w", encoding="utf-8") as fh:
        fh.write(content)
    print("inject_watchdog: watchdog v4 da duoc inject vao %s" % hook)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
