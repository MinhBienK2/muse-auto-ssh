#!/usr/bin/env python3
"""Render prompt dan cho Agent Muse tu template.

Repo co DUNG MOT prompt:
  .agents/setup-ssh-muse/reference/MUSE_PROMPT.template.md -> MUSE_PROMPT.md

Noi dung prompt nam trong skill (reference/) vi skill la noi duy nhat mo ta
"ket noi 1 may Muse moi" - ca quy trinh agent, ca prompt dan sang Muse.

Prompt khong nhung source code bus: code di qua kenh SSH da xac thuc (bundle keo tu may ngoai),
nen khong lo bo loc an toan cua Agent Muse.

Usage:
    python3 scripts/render_prompt.py                              # -> MUSE_PROMPT.md
    python3 scripts/render_prompt.py --stdout
    python3 scripts/render_prompt.py --host-id muse4 --port 2225
    python3 scripts/render_prompt.py --host <TAILSCALE_IP> --user <USER> --port 2223
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_OUT = os.path.join(REPO, "MUSE_PROMPT.md")
PROXY_PY = os.path.join(REPO, "bridge", "ts-connect-proxy.py")
TEMPLATE = os.path.join(
    REPO, ".agents", "setup-ssh-muse", "reference", "MUSE_PROMPT.template.md"
)
PLACEHOLDER_RE = re.compile(r"\{\{([A-Z0-9_]+)\}\}")

# Gia tri co dinh cua container Muse (khong phu thuoc may cua nguoi dung).
MUSE_BASE = "/home/hatch/workspace/muse-platform-setup"
MUSE_SPOOL = "/root/.muse-bridge"


def sh(cmd: list) -> str:
    try:
        out = subprocess.run(cmd, text=True, capture_output=True, timeout=20)
        return out.stdout.strip()
    except Exception:  # noqa: BLE001
        return ""


def detect_host() -> str:
    ip = sh(["tailscale", "ip", "-4"])
    if ip:
        return ip.splitlines()[0].strip()
    ip = sh(["ip", "-brief", "addr", "show", "tailscale0"])
    if ip:
        parts = ip.split()
        if len(parts) >= 3:
            return parts[2].split("/")[0]
    return ""


def detect_pubkey() -> str:
    """Public key cua may ngoai, bo comment (chi giu "ssh-ed25519 AAAA...").

    Comment cua key chua ten may (vi du "user@host") -> khong nen dua vao prompt.
    """
    for path in (os.path.expanduser("~/.ssh/id_ed25519.pub"), os.path.expanduser("~/.ssh/id_rsa.pub")):
        if os.path.isfile(path):
            with open(path, "r", encoding="utf-8") as fh:
                line = fh.read().strip()
            parts = line.split()
            if len(parts) >= 2:
                return " ".join(parts[:2])
            return line
    return ""


def detect_bundle_dir() -> str:
    return os.path.join(os.path.expanduser("~/.muse-bridge"), "bundle")


def read_proxy_helper() -> str:
    """Noi dung helper proxy Python - inject vao prompt "mot lan".

    Ban goc duy nhat la bridge/ts-connect-proxy.py: prompt va container deu dung
    cung mot file nen khong the lech phien ban.
    """
    try:
        with open(PROXY_PY, "r", encoding="utf-8") as fh:
            return fh.read().rstrip("\n")
    except OSError:
        return ""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="")
    ap.add_argument("--user", default="")
    ap.add_argument("--pubkey", default="")
    ap.add_argument("--spool", default="")
    ap.add_argument("--port", type=int, default=2222)
    ap.add_argument("--hostname", default="")
    ap.add_argument("--host-id", default="muse")
    ap.add_argument("--bundle-dir", default="")
    ap.add_argument("--out", default="")
    ap.add_argument("--stdout", action="store_true")
    args = ap.parse_args()

    if not os.path.isfile(TEMPLATE):
        print(
            "render_prompt: khong tim thay template: %s\n"
            "  (template nam trong skill .agents/setup-ssh-muse/reference/ - "
            "clone repo day du hoac checkout nhanh feat/quickly-ssh)" % TEMPLATE,
            file=sys.stderr,
        )
        return 1
    with open(TEMPLATE, "r", encoding="utf-8") as fh:
        text = fh.read()
    # Comment HTML dau file la ghi chu cho nguoi bao tri (ngan sach prompt...)
    # -> cat khoi ban render de khong ton ngan sach va khong lo vao chat Muse.
    text = re.sub(r"<!--.*?-->\n?", "", text, flags=re.DOTALL)

    values = {
        "LOCAL_HOST": args.host or detect_host(),
        "LOCAL_USER": args.user or sh(["id", "-un"]),
        "LOCAL_PUBKEY": args.pubkey or detect_pubkey(),
        "LOCAL_SPOOL": args.spool or os.path.expanduser("~/.muse-bridge"),
        "LOCAL_PORT": str(args.port),
        "LOCAL_HOSTNAME": args.hostname or sh(["hostname"]),
        "HOST_ID": args.host_id,
        "BUNDLE_DIR": args.bundle_dir or detect_bundle_dir(),
        "MUSE_BASE": MUSE_BASE,
        "MUSE_SPOOL": MUSE_SPOOL,
        "PROXY_PY": read_proxy_helper(),
    }

    missing = []
    for name in sorted(set(PLACEHOLDER_RE.findall(text))):
        if name not in values:
            missing.append(name)
            continue
        text = text.replace("{{%s}}" % name, values[name])
    if missing:
        print("render_prompt: placeholder chua co gia tri: %s" % ", ".join(missing), file=sys.stderr)
        return 1
    if not values["LOCAL_HOST"] or not values["LOCAL_PUBKEY"]:
        print("render_prompt: thieu host/public key - chay 'bridge.sh arm' truoc", file=sys.stderr)
        return 1
    if not values["PROXY_PY"]:
        print("render_prompt: thieu bridge/ts-connect-proxy.py", file=sys.stderr)
        return 1

    if args.stdout:
        sys.stdout.write(text)
        return 0
    out = args.out or DEFAULT_OUT
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(text)
    print("render_prompt: %s (%d bytes)" % (out, len(text)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
