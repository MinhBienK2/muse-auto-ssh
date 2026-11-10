#!/usr/bin/env python3
"""Cap nhat trang thai the sinh vao .muse-hosts/<id>.json (card thong tin ket noi, gitignored).

Usage: python3 scripts/update_host_state.py <card.json> <port> [--thread URL]
"""

from __future__ import annotations

import datetime
import json
import os
import subprocess
import sys


def main() -> int:
    args = sys.argv[1:]
    thread = ""
    if "--thread" in args:
        i = args.index("--thread")
        try:
            thread = args[i + 1]
        except IndexError:
            print("--thread can mot gia tri (URL)", file=sys.stderr)
            return 2
        args = args[:i] + args[i + 2 :]
    if len(args) != 2:
        print(__doc__)
        return 2
    path, port = args[0], int(args[1])
    card = {}
    if os.path.exists(path):
        try:
            with open(path, "r", encoding="utf-8") as fh:
                card = json.load(fh)
        except (OSError, ValueError):
            card = {}
    listening = (
        subprocess.run(
            ["bash", "-lc", "ss -tln 2>/dev/null | grep -q ':%d\\b'" % port],
            capture_output=True,
        ).returncode
        == 0
    )
    card["tunnel_port"] = port
    card["state"] = "connected" if listening else "waiting"
    card["checked"] = datetime.datetime.now().isoformat(timespec="seconds")
    if thread:
        card["thread"] = thread
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(card, fh, indent=2, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
