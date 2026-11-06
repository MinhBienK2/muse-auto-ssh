#!/bin/bash
# ==============================================================================
# bridge.sh - CLI phia may ngoai (Agent Ngoai goi lenh nay).
#
#   hosts                      danh sach cac Muse host da dang ky
#   add-host --host <id>       dang ky Muse host moi (port, ssh alias, spool)
#   onboard --host <id>       \x{1}trong suot: dang ky -> gui prompt qua web Muse -> xac nhan
#   arm --host <id>            chuan bi moi truong may ngoai (idempotent)
#   status --host <id>         trang thai kenh hai chieu
#   inbox --host <id>          doc tin nhan gui tu Muse
#   send --host <id> --type .. gui tin nhan cho Muse
#   ack --host <id> <id>       danh dau da xu ly
#   sync --host <id>           gui lai cac tin choang gui (pending)
#   daemon --host <id>         watcher inbox (log + thong bao desktop)
#   prompt --host <id>         render MUSE_PROMPT.md cho host do
#   push --host <id>           day bundle moi len host do
#   authorize --host <id> --key '<ssh-ed25519 ...>'  them key cua Muse
#   selftest                   kiem tra bus hai huong (khong can mang)
# ==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_SIDE="$REPO_DIR/bridge/local_side.sh"

case "${1:-}" in
  hosts)     shift; bash "$LOCAL_SIDE" hosts "$@" ;;
  add-host)  shift; bash "$LOCAL_SIDE" add-host "$@" ;;
  onboard)   shift; bash "$LOCAL_SIDE" onboard "$@" ;;
  arm)       shift; bash "$LOCAL_SIDE" arm "$@" ;;
  status)    shift; bash "$LOCAL_SIDE" status "$@" ;;
  inbox)     shift; bash "$LOCAL_SIDE" inbox "$@" ;;
  send)      shift; bash "$LOCAL_SIDE" send "$@" ;;
  ack)       shift; bash "$LOCAL_SIDE" ack "$@" ;;
  sync)      shift; bash "$LOCAL_SIDE" sync "$@" ;;
  daemon)    shift; bash "$LOCAL_SIDE" daemon "$@" ;;
  prompt)    shift; bash "$LOCAL_SIDE" prompt "$@" ;;
  push)      shift; bash "$LOCAL_SIDE" push "$@" ;;
  authorize) shift; bash "$LOCAL_SIDE" authorize "$@" ;;
  selftest)  shift; bash "$REPO_DIR/tests/run_all.sh" ;;
  *) sed -n '2,28p' "$0"; exit 2 ;;
esac
