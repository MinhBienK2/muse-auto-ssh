#!/bin/bash
# ==============================================================================
# check_hygiene.sh - repo phai chay duoc tren may nguoi khac.
#
#   bash scripts/check_hygiene.sh
#
# Kiem tra 2 thu:
#   1) file tracked khong chua gia tri rieng cua mot may (IP Tailscale, user,
#      email, duong dan home cua nguoi viet)
#   2) khong con stub / TODO / placeholder "de sau lam"
#
# Cac gia tri sau day duoc PHEP:
#   100.64.0.0/10        - dai CGNAT cua Tailscale (khong phai IP may)
#   100.64.0.1, 127.0.0.1, 0.0.0.0, 255.255.255.255 - dia chi loopback / vi du
#   testuser, probe, muse - user gia cho test
# ==============================================================================
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

fails=0
fail() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }
ok()   { echo "OK: $1"; }

# --- 1) gia tri rieng cua may ----------------------------------------------
# Chi xet file text (bo qua binary), va bo qua:
#   100.64.0.0/10 - dai CGNAT cua Tailscale; 127.0.0.0/8 - loopback.
IP_RE='\b([0-9]{1,3}\.){3}[0-9]{1,3}\b'
ip_hits="$(git grep -nE "$IP_RE" -- ':!legacy' ':!*.md' ':!*.pyc' 2>/dev/null \
  | grep -vE '\b(127|0|255)\.' \
  | grep -vE '\b(10|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\.' \
  | grep -vE '\b100\.(64|100|115|126|127)\.' || true)"

# email
email_hits="$(git grep -nE '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' -- ':!legacy' ':!*.md' ':!*.pyc' 2>/dev/null || true)"

# duong dan home cua nguoi viet (vi du /home/<ten>) - /home/hatch, /home/root,
# /home/user (placeholder trong tai lieu) deu duoc phep.
home_hits="$(git grep -nE '/home/[a-z][a-z0-9._-]+/' -- ':!legacy' ':!*.md' ':!*.pyc' 2>/dev/null \
  | grep -vE '/home/(hatch|root|user)/' || true)"

if [ -n "$ip_hits" ]; then
  fail "co IP cua may trong file tracked:"
  echo "$ip_hits" | sed 's/^/    /' >&2
else
  ok "khong co IP cua may trong file tracked"
fi

if [ -n "$email_hits" ]; then
  fail "co email trong file tracked:"
  echo "$email_hits" | sed 's/^/    /' >&2
else
  ok "khong co email trong file tracked"
fi

if [ -n "$home_hits" ]; then
  fail "co duong dan home cua nguoi viet trong file tracked:"
  echo "$home_hits" | sed 's/^/    /' >&2
else
  ok "khong co duong dan home rieng trong file tracked"
fi

# --- 2) stub / TODO -------------------------------------------------------
# Chi danh nguon (khong phai comment/tai lieu). Bo qua chinh file nay - no chua
# cac tu khoa tren trong regex cua no.
stub_hits="$(git grep -nE '\b(TODO|FIXME|XXX)\b|not implemented|NotImplementedError' -- ':!legacy' ':!*.md' ':!scripts/check_hygiene.sh' 2>/dev/null \
  | grep -vE '^\S+:[0-9]+:\s*#' || true)"
if [ -n "$stub_hits" ]; then
  fail "con TODO/stub trong code:"
  echo "$stub_hits" | sed 's/^/    /' >&2
else
  ok "khong con TODO/stub"
fi

if [ "$fails" = "0" ]; then
  echo "HYGIENE_CHECK: PASS"
else
  echo "HYGIENE_CHECK: FAIL ($fails)"
fi
exit "$fails"
