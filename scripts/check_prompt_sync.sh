#!/bin/bash
# ==============================================================================
# check_prompt_sync.sh - MUSE_PROMPT.md la artifact sinh ra, phai khop voi
# ma nguon hien tai (template + bridge/bridge.py + bridge/muse_side.sh).
#
#   bash scripts/check_prompt_sync.sh
#
# FAIL => chay: python3 scripts/render_prompt.py
# ==============================================================================
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ ! -f MUSE_PROMPT.md ]; then
  echo "FAIL: khong co MUSE_PROMPT.md"
  exit 1
fi

python3 scripts/render_prompt.py --out "$TMP/MUSE_PROMPT.md" >/dev/null || {
  echo "FAIL: render_prompt.py loi"
  exit 1
}

if diff -u "$TMP/MUSE_PROMPT.md" MUSE_PROMPT.md; then
  echo "OK: MUSE_PROMPT.md dong bo voi template + bridge/*.py|sh"
  exit 0
fi

echo "FAIL: MUSE_PROMPT.md lech voi ma nguon hien tai (xem diff tren)"
echo "      sua bang: python3 scripts/render_prompt.py"
exit 1
