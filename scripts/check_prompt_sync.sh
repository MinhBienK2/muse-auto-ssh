#!/bin/bash
# ==============================================================================
# check_prompt_sync.sh - kiem tra prompt dung template + khong chua ma nguon.
#
#   bash scripts/check_prompt_sync.sh            # kiem tra (may-agnostic)
#   bash scripts/check_prompt_sync.sh --strict   # CI: chi kiem tra may-agnostic
#
# MUSE_PROMPT.md la ARTIFACT RENDER (khong commit - no IP/user/pubkey cua may
# that). File nay nen KHONG doc/ghi phia may nguoi, va khong fail tren may khac.
#
#   1) (luon) render template voi gia tri gia dinh -> khong con placeholder,
#      khong chua source code bus, kich thuoc trong gioi han.
#   2) (chi khi khong --strict) neu MUSE_PROMPT.md ton tai tren may nay, no
#      phai dung bang ban render moi nhat (phat hien "sua template xong quen
#      render lai").
# ==============================================================================
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

STRICT=0
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    *) echo "usage: check_prompt_sync.sh [--strict]" >&2; exit 2 ;;
  esac
done

fails=0
fail() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }
ok()   { echo "OK: $1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1) kiem tra may-agnostic: render voi gia tri co dinh --------------------
python3 scripts/render_prompt.py \
  --host 100.64.0.1 --user probe --pubkey "ssh-ed25519 AAAAprobe" \
  --port 2222 --spool /tmp/probe --hostname probe \
  --out "$TMP/MUSE_PROMPT.md" >/dev/null || {
  fail "render_prompt.py loi"
  exit 1
}

if grep -q '{{[A-Z0-9_]*}}' "$TMP/MUSE_PROMPT.md"; then
  fail "template con placeholder chua thay:"
  grep -o '{{[A-Z0-9_]*}}' "$TMP/MUSE_PROMPT.md" | sort -u | sed 's/^/    /' >&2
else
  ok "template render khong con placeholder"
fi

# Prompt phai ngan: bo loc an toan cua Agent Muse chan "khong script lon".
size=$(wc -c < "$TMP/MUSE_PROMPT.md")
if [ "$size" -ge 12000 ]; then
  fail "prompt qua dai ($size B, gioi han 12000 B) - co the bi bo loc an toan chan"
else
  ok "prompt ngan ($size B < 12000 B)"
fi

# Prompt khong duoc chua source code cua bus (chi nen co ma ngan).
if grep -qE 'MUSE_BRIDGE_PY_EOF|MUSE_SIDE_SH_EOF|MUSE_INJECT_WD_EOF' "$TMP/MUSE_PROMPT.md"; then
  fail "prompt chua source code bus - se bi bo loc an toan cua Muse chan"
else
  ok "prompt khong chua source code bus"
fi

# Prompt phai co du 4 buoc + phan bus sau khi kenh thong.
for needle in "Bước 1" "Bước 2" "Bước 3" "Bước 4" "bridge.py inbox" "bridge.py send" "bridge.py ack"; do
  grep -q "$needle" "$TMP/MUSE_PROMPT.md" || fail "prompt thieu '$needle'"
done
[ "$fails" = "0" ] && ok "prompt co du 4 buoc + phan bus"

# --- 2) kiem tra may-local: MUSE_PROMPT.md co dung ban render moi nhat khong? --
if [ "$STRICT" = "0" ] && [ -f MUSE_PROMPT.md ]; then
  if python3 scripts/render_prompt.py --out "$TMP/local.md" >/dev/null 2>&1; then
    if diff -u "$TMP/local.md" MUSE_PROMPT.md > "$TMP/diff.txt"; then
      ok "MUSE_PROMPT.md dong bo voi template (may nay)"
    else
      fail "MUSE_PROMPT.md lech voi ma nguon hien tai (xem diff tren)"
      sed -n '1,40p' "$TMP/diff.txt" >&2
      echo "      sua bang: python3 scripts/render_prompt.py" >&2
    fi
  else
    echo "skip: khong detect duoc host/public key tren may nay - bo qua kiem tra MUSE_PROMPT.md"
  fi
fi

if [ "$fails" = "0" ]; then
  echo "PROMPT_CHECK: PASS"
else
  echo "PROMPT_CHECK: FAIL ($fails)"
fi
exit "$fails"
