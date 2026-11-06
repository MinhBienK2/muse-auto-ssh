#!/usr/bin/env python3
"""Render MUSE_PROMPT.md tu templates/MUSE_PROMPT.template.md + bundle phia Muse.

Mot nguon su that: bus core (bridge/bridge.py) va bundle Muse (bridge/muse_side.sh)
duoc embed nguyen van vao prompt => hai agent chay cung mot code.

Usage:
    python3 scripts/render_prompt.py                # -> MUSE_PROMPT.md
    python3 scripts/render_prompt.py --stdout       # in ra stdout
    python3 scripts/render_prompt.py --host 100.120.205.53 --user minhbien
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEMPLATE = os.path.join(REPO, "templates", "MUSE_PROMPT.template.md")
BRIDGE_PY = os.path.join(REPO, "bridge", "bridge.py")
MUSE_SIDE = os.path.join(REPO, "bridge", "muse_side.sh")
INJECT_WD = os.path.join(REPO, "bridge", "inject_watchdog.py")
DEFAULT_OUT = os.path.join(REPO, "MUSE_PROMPT.md")

PLACEHOLDER_RE = re.compile(r"\{\{[A-Z0-9_]+\}\}")


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
    for path in (os.path.expanduser("~/.ssh/id_ed25519.pub"), os.path.expanduser("~/.ssh/id_rsa.pub")):
        if os.path.isfile(path):
            with open(path, "r", encoding="utf-8") as fh:
                return fh.read().strip()
    return ""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="")
    ap.add_argument("--user", default="")
    ap.add_argument("--pubkey", default="")
    ap.add_argument("--spool", default="")
    ap.add_argument("--hostname", default="")
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--stdout", action="store_true")
    args = ap.parse_args()

    with open(TEMPLATE, "r", encoding="utf-8") as fh:
        text = fh.read()
    with open(BRIDGE_PY, "r", encoding="utf-8") as fh:
        bridge_src = fh.read().rstrip("\n")
    with open(MUSE_SIDE, "r", encoding="utf-8") as fh:
        muse_src = fh.read().rstrip("\n")
    with open(INJECT_WD, "r", encoding="utf-8") as fh:
        inject_src = fh.read().rstrip("\n")

    for src, name in ((bridge_src, "bridge.py"), (muse_src, "muse_side.sh"), (inject_src, "inject_watchdog.py")):
        for marker in ("MUSE_BRIDGE_PY_EOF", "MUSE_SIDE_SH_EOF", "MUSE_INJECT_WD_EOF"):
            if marker in src:
                print("render_prompt: %s chua marker %s" % (name, marker), file=sys.stderr)
                return 1

    values = {
        "LOCAL_HOST": args.host or detect_host(),
        "LOCAL_USER": args.user or sh(["id", "-un"]),
        "LOCAL_PUBKEY": args.pubkey or detect_pubkey(),
        "LOCAL_SPOOL": args.spool or os.path.expanduser("~/.muse-bridge"),
        "LOCAL_HOSTNAME": args.hostname or sh(["hostname"]),
        "BRIDGE_PY": bridge_src,
        "MUSE_SIDE_SH": muse_src,
        "INJECT_WATCHDOG_PY": inject_src,
    }
    for key, value in values.items():
        text = text.replace("{{%s}}" % key, value)

    leftovers = sorted(set(PLACEHOLDER_RE.findall(text)))
    if leftovers:
        print("render_prompt: chua thay placeholder: %s" % ", ".join(leftovers), file=sys.stderr)
        return 1

    if args.stdout:
        sys.stdout.write(text)
        return 0
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write(text)
    print("render_prompt: %s (%d bytes)" % (args.out, len(text)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
