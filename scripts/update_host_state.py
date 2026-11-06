#!/usr/bin/env python3
"""Cap nhat trang thai the sinh vao .muse-hosts/<id>.json (card thong tin ket noi, gitignored).

Usage: python3 scripts/update_host_state.py <card.json> <port>
"""

from __future__ import annotations

import datetime
import json
import os
import subprocess
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    path, port = sys.argv[1], int(sys.argv[2])
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
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(card, fh, indent=2, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
