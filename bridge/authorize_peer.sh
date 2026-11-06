#!/bin/bash
# ==============================================================================
# authorize_peer.sh - AuthorizedKeysCommand cho sshd: TOFU cho peer tailnet.
#
# Tham so sshd truyen vao: $1=user $2=host $3=keytype $4=key
# - Chi chap nhan peer co IP trong tailnet Tailscale (100.64.0.0/10, fd7a:.../48).
# - Key moi duoc pin 1 lan; ghi lai trong ~/.muse-bridge/peers.log.
# - Quyen han: khong PTY, khong agent forwarding, khong X11.
# ==============================================================================
set -u
STATE="$HOME/.muse-bridge"
KEY="${4:-}"
[ -n "$KEY" ] || exit 0
[ -f "$STATE/tofu.enabled" ] || exit 0

PEER="${SSH_CLIENT%% *}"
[ -n "$PEER" ] || PEER="${2:-}"
case "$PEER" in
  100.*|fd7a:*) : ;;
  *) exit 0 ;;
esac

FP="$(printf '%s\n' "$KEY" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')"
[ -n "$FP" ] || exit 0

mkdir -p "$STATE/peers" 2>/dev/null || exit 0
if [ ! -f "$STATE/peers/$FP" ]; then
  printf '%s\n' "$KEY" > "$STATE/peers/$FP"
  printf '%s\t%s\t%s\t%s\n' "$(date -Is)" "$FP" "$PEER" "$KEY" >> "$STATE/peers.log"
fi

printf 'from="100.64.0.0/10,fd7a:115c:a1e0::/48",no-agent-forwarding,no-X11-forwarding,no-pty %s\n' "$KEY"
