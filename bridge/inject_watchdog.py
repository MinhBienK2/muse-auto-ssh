#!/usr/bin/env python3
"""Inject (or upgrade) the muse-bridge watchdog into the Hatch boot hook.

Usage:
    python3 inject_watchdog.py <hook.sh> <loop.sh> <key> <proxy.sh> <user> <host>

Idempotent:
  - block v1 (chi pgrep) duoc go va thay bang v2 (kiem tra chuc nang).
  - block v2 cu duoc go roi inject lai.
"""

from __future__ import annotations

import os
import re
import sys

BEGIN = "# [muse-bridge watchdog v3] BEGIN"
END = "# [muse-bridge watchdog v3] END"

BLOCK = """
# [muse-bridge watchdog v3] BEGIN
mkdir -p /run/sshd /var/run/sshd
# 1) sshd phai TRA LOI duoc banner tren :22 (pgrep khong du - sshd treo van bi bo qua)
if ! timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/22; head -c 4 <&3' 2>/dev/null | grep -q SSH; then
    pkill -x sshd >/dev/null 2>&1 || true
    sleep 1
    /usr/sbin/sshd >/dev/null 2>&1 || true
fi
# 2) dam bao co MOT supervisor cho tunnel:
#    - co systemd -> service la chinh, hook chi kick no
#    - khong co systemd -> hook tu chay loop
if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
    systemctl is-active --quiet muse-reverse-tunnel.service 2>/dev/null || \
        systemctl start muse-reverse-tunnel.service >/dev/null 2>&1 || true
else
    if ! pgrep -f 'ssh -N -R' >/dev/null 2>&1; then
        nohup /bin/bash %(loop)s >> %(log)s >/dev/null 2>&1 &
    fi
fi
# [muse-bridge watchdog v3] END
"""


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

    for pat in (
        r"\n?# \[Self-healing: Auto keep SSH and G3 Reverse Tunnel alive\].*?reverse-tunnel.*?\nfi\n",
        r"\n?# \[muse-bridge watchdog v3\] BEGIN.*?# \[muse-bridge watchdog v3\] END\n",
    ):
        content = re.sub(pat, "", content, flags=re.S)

        log = loop.rsplit("/", 1)[0] + "/tunnel.log"
    inject = BLOCK % {
        "loop": loop,
        "log": log,
        "key": key,
        "proxy": proxy,
        "user": user,
        "host": host,
    }

    anchor = "set -euo pipefail\n"
    if anchor in content:
        i = content.find(anchor)
        content = content[: i + len(anchor)] + inject + content[i + len(anchor) :]
    else:
        content = inject + content

    with open(hook, "w", encoding="utf-8") as fh:
        fh.write(content)
    print("inject_watchdog: watchdog v2 da duoc inject vao %s" % hook)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
