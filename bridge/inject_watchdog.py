#!/usr/bin/env python3
"""Inject (or upgrade) the muse-bridge watchdog into the Hatch boot hook.

Usage:
    python3 inject_watchdog.py <hook.sh> <loop.sh> <key> <proxy.sh> <user> <host>

Idempotent:
  - moi block watchdog cu (v1..v5) deu bi go, chi con block v6.
  - block v6 inject lai deu an toan (thay bang chinh no).

v4 sua 3 loi cu gay CHET kenh:
  - supervisor phai theo PORT (unit per-port + pgrep theo port), tranh 2 host
    tren cung container du vao chung 1 supervisor -> "remote port forwarding
    failed for listen port <port>" -> vong lap reconnect lien tuc.
  - systemd duoc detect bang /run/systemd/system, khong dung
    `systemctl is-system-running` (tra exit != 0 khi system "degraded",
    lam watchdog tu chay loop chung voi unit -> 2 supervisor).
  - block watchdog cu (v1/v2/v3) bi xoa sach, tranh hook va unit cung kick
    nhau 2 lan.

v6 sua 2 loi con "silent":
  - hook PHAI ket thuc bang HATCH_HOOK_RESULT. Hook moi (chi co block watchdog)
    khong define ham `silent` -> Hatch bao loi "script exited without calling
    silent() or wake()" -> hook bi coi la FAIL -> watchdog vô hiệu, container
    sau khi refresh khong con tu cai lai unit/authorized_keys.
  - block cu bi chen TRUOC shebang (va shebang bi dan vao dong cuoi block) ->
    file hook mat shebang -> Hatch khong chay duoc script.
"""

from __future__ import annotations

import os
import re
import sys

BEGIN = "# [muse-bridge watchdog v6] BEGIN"
END = "# [muse-bridge watchdog v6] END"

# Template dung placeholder "@@NAME@@" + str.replace, KHONG dung "%"-format.
# Ly do: "%"-format se an mat moi "%" literal trong shell (vi du "date +%s" ->
# "date +{'port': '2222'}") -> nhanh tay lam hong CHINH nhanh tu cai openssh-server.
# Dung "@@" thi "%" trong shell luon an toàn.
BLOCK = """
# [muse-bridge watchdog v6] BEGIN
# Block chay sau "set -euo pipefail" -> phai tu phong loi (hook khong duoc FAIL)
set +e
set +u
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
# 1b) container refresh xoa luon openssh-server (image khong chua san) -> cai lai
if [ ! -x /usr/sbin/sshd ] && command -v apt-get >/dev/null 2>&1; then
    MARK="/home/hatch/.muse-bridge/.openssh_retry"
    NOW="$(date +%s)"; LAST="$(cat "$MARK" 2>/dev/null || echo 0)"
    if [ $((NOW - LAST)) -gt 600 ]; then
        echo "$NOW" > "$MARK" 2>/dev/null || true
        export http_proxy="http://hatch-egress-proxy:3130" https_proxy="http://hatch-egress-proxy:3130"
        export HTTP_PROXY="$http_proxy" HTTPS_PROXY="$https_proxy"
        timeout 25 apt-get update -qq >/dev/null 2>&1 || true
        timeout 25 apt-get install -y -qq openssh-server >/dev/null 2>&1 || true
    fi
fi
if ! timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/22; head -c 4 <&3' 2>/dev/null | grep -q SSH; then
    pkill -x sshd >/dev/null 2>&1 || true
    sleep 1
    /usr/sbin/sshd >/dev/null 2>&1 || true
fi
# 2) dam bao co DUNG MOT supervisor cho port @@PORT@@:
#    - co systemd -> unit per-port la CHINH, hook chi kick no
#    - khong co systemd -> hook tu chay loop
UNIT="muse-reverse-tunnel-@@PORT@@.service"
TPL="@@TPL@@"
HAVE_SYSTEMD=0
if [ -d /run/systemd/system ]; then
    HAVE_SYSTEMD=1
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
#    3a) container tu keo bundle ve -> cap nhat script loop dang chay (atomic:
#        ghi .new roi mv, vi bash doc file theo offset nen ghi de ghi se hong).
LOOP_SCRIPT="@@LOOP@@"
BUNDLE_LOOP="/home/hatch/.muse-bridge/bundle/reverse-tunnel.sh"
if [ -f "$BUNDLE_LOOP" ] && [ -f "$LOOP_SCRIPT" ] && ! cmp -s "$BUNDLE_LOOP" "$LOOP_SCRIPT"; then
    cp -f "$BUNDLE_LOOP" "$LOOP_SCRIPT.new" 2>/dev/null && mv -f "$LOOP_SCRIPT.new" "$LOOP_SCRIPT" 2>/dev/null
    chmod 700 "$LOOP_SCRIPT" 2>/dev/null || true
fi
#    3b) proxy helper cung phai moi (duong truc tiep truoc, proxy sau) - ban
#        cu khong ProxyCommand hay treo o "banner exchange".
BUNDLE_PROXY="/home/hatch/.muse-bridge/bundle/ts-socat-proxy.sh"
TUNNEL_DIR="$(dirname "$LOOP_SCRIPT")"
if [ -f "$BUNDLE_PROXY" ] && [ -d "$TUNNEL_DIR" ] && ! cmp -s "$BUNDLE_PROXY" "$TUNNEL_DIR/ts-socat-proxy.sh"; then
    cp -f "$BUNDLE_PROXY" "$TUNNEL_DIR/ts-socat-proxy.sh.new" 2>/dev/null \
        && mv -f "$TUNNEL_DIR/ts-socat-proxy.sh.new" "$TUNNEL_DIR/ts-socat-proxy.sh" 2>/dev/null
    chmod 700 "$TUNNEL_DIR/ts-socat-proxy.sh" 2>/dev/null || true
fi
#    SO SAN GIA TRI THUAN cua LOOP_VERSION (v7), khong phai ca cum "LOOP_VERSION=\"v7\"".
#    Sai cach nay -> restart lien tuc -> tunnel chop chop.
WANT="$(grep -o 'LOOP_VERSION="[^"]*"' "@@LOOP@@" 2>/dev/null | head -1 | sed 's/.*="//; s/"$//' || true)"
HAVE="$(cat "$(dirname "@@LOG@@")/.loop_version" 2>/dev/null | tr -d '[:space:]' || true)"
if [ -n "$WANT" ] && [ "$WANT" != "$HAVE" ]; then
    if [ "$HAVE_SYSTEMD" = "1" ] && [ -f "/etc/systemd/system/$UNIT" ]; then
        # systemd restart thay vi pkill: pkill lam race voi Restart=always -> 2 supervisor
        systemctl restart "$UNIT" >/dev/null 2>&1 || true
    else
        pkill -f "[b]ash @@LOOP@@" >/dev/null 2>&1 || true
        pkill -f "[s]sh -N -R @@PORT@@:" >/dev/null 2>&1 || true
    fi
    sleep 2
fi
# 4) fallback: CHI khi khong co systemd unit moi tu chay loop
#    (co unit thi hook KHONG duoc spawn them -> 2 supervisor tranh port -R)
if [ "$HAVE_SYSTEMD" != "1" ] || [ ! -f "/etc/systemd/system/$UNIT" ]; then
    if ! pgrep -f 'ssh -N -R @@PORT@@:' >/dev/null 2>&1; then
        nohup /bin/bash @@LOOP@@ >> @@LOG@@ >/dev/null 2>&1 &
    fi
fi
set -eu
# [muse-bridge watchdog v6] END
"""

# TAIL: hook PHAI ket thuc bang HATCH_HOOK_RESULT (Hatch goi "failed" neu thieu).
# Hook vua tao (chi co block watchdog) khong define ham `silent` -> tu define
# roi ket thuc o day. Hook da co silent that (muse-platform) -> da thoat truoc
# TAIL, dong nay khong duoc chay.
TAIL = """
# [muse-bridge watchdog v6] TAIL
if ! declare -F silent >/dev/null 2>&1; then
    silent() { printf 'HATCH_HOOK_RESULT:{"decision":"silent","reason":"%s"}\\n' "${1:-ok}"; exit 0; }
fi
silent "muse-bridge watchdog hook ok"
"""

# Moi block watchdog cu deu phai bi go - chi con duy nhat block v6.
# `END\n?`: block cu co the bi chen truoc shebang, khi do shebang bi dan vao
# cung dong voi `END` (khong con newline) -> phai go ca `END` ma giu nguyen
# phan "...!/usr/bin/env bash" con lai.
OLD_BLOCK_PATTERNS = (
    r"\n?# \[Self-healing: Auto keep SSH and G3 Reverse Tunnel alive\].*?reverse-tunnel.*?\nfi\n",
    r"\n?# \[muse-bridge watchdog v\d+\] BEGIN.*?# \[muse-bridge watchdog v\d+\] END\n?",
    r"\n?# \[muse-bridge watchdog v\d+\] TAIL.*?silent \"muse-bridge watchdog hook ok\"\n?",
    r"\n?silent \"muse-bridge watchdog ok\"[^\n]*\n",
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
    port = port_from_loop(loop)
    tpl = loop.rsplit("/", 1)[0] + "/muse-reverse-tunnel-%s.service.template" % port
    # Substitute bang str.replace (khong phai "%"-format): "%" trong shell block
    # (vi du "date +%s") phai duoc giu nguyen.
    inject = BLOCK
    for token, value in (
        ("@@PORT@@", port),
        ("@@TPL@@", tpl),
        ("@@LOOP@@", loop),
        ("@@LOG@@", log),
    ):
        inject = inject.replace(token, value)
    if "@@" in inject:
        print(
            "inject_watchdog: con placeholder chua thay trong block: %s" % inject,
            file=sys.stderr,
        )
        return 1

    # Block phai khong duoc lam script hook "fail" (set -e).
    body = inject.rstrip("\n") + "\n"
    # TAIL: hook phai LUON ket thuc bang HATCH_HOOK_RESULT (Hatch goi "failed"
    # neu hook thoat ma khong goi silent/wake). Append o cuoi file.
    tail = TAIL.rstrip("\n") + "\n"
    # Block phai nam SAU shebang + sau "set -euo pipefail":
    #   - truoc shebang -> script mat shebang -> khong chay duoc
    #   - truoc set -e  -> len block khong duoc strict mode
    # File hook cu thuong ket thuc bang "set -euo pipefail" KHONG co newline
    # -> dung regex (newline optional), con neu khong tim thay -> chen sau shebang.
    m = re.search(r"^set -euo pipefail[ \t]*\n?", content, flags=re.M)
    if m:
        content = content[: m.end()] + body + content[m.end() :]
    else:
        m = re.search(r"^#!.*\n", content, flags=re.M)
        if m:
            content = content[: m.end()] + body + content[m.end() :]
        else:
            content = body + content

    content = content.rstrip("\n") + "\n" + tail

    with open(hook, "w", encoding="utf-8") as fh:
        fh.write(content)
    print("inject_watchdog: watchdog v6 da duoc inject vao %s" % hook)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
