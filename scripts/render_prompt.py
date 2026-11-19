#!/usr/bin/env python3
"""Render prompt dan cho Agent Muse tu template.

Hai bien (cung mot renderer, hai template):
  - short   : MUSE_PROMPT.template.md  -> MUSE_PROMPT.md     (4 buoc, dung cho chat da chay)
  - oneshot : MUSE_ONESHOT.template.md -> MUSE_ONESHOT.md   (day du thong so, dan 1 lan la xong)

Prompt khong nhung source code bus: code di qua kenh SSH da xac thuc (bundle keo tu may ngoai),
nen khong lo bo loc an toan cua Agent Muse.

Usage:
    python3 scripts/render_prompt.py                              # -> MUSE_PROMPT.md
    python3 scripts/render_prompt.py --stdout
    python3 scripts/render_prompt.py --variant oneshot --host-id muse4 --port 2225
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
VARIANTS = {
    "short": ("MUSE_PROMPT.template.md", DEFAULT_OUT),
    "oneshot": ("MUSE_ONESHOT.template.md", os.path.join(REPO, "MUSE_ONESHOT.md")),
}
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
    ap.add_argument("--variant", choices=sorted(VARIANTS), default="short")
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

    template_name, default_out = VARIANTS[args.variant]
    template = os.path.join(REPO, "templates", template_name)

    with open(template, "r", encoding="utf-8") as fh:
        text = fh.read()

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
    if args.variant == "oneshot" and not values["PROXY_PY"]:
        print("render_prompt: thieu bridge/ts-connect-proxy.py", file=sys.stderr)
        return 1

    if args.stdout:
        sys.stdout.write(text)
        return 0
    out = args.out or default_out
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(text)
    print("render_prompt: %s (%d bytes)" % (out, len(text)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
