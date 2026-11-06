#!/bin/bash
# ==============================================================================
# bridge.sh - CLI phia may ngoai (Agent Ngoai goi lenh nay).
#
#   arm              chuan bi moi truong may ngoai (idempotent) + in prompt
#   status           trang thai kenh hai chieu
#   inbox [--watch]  doc tin nhan gui tu Muse
#   send ...         gui tin nhan cho Muse
#   ack <id>         danh dau da xu ly
#   sync             gui lai cac tin choang gui (pending)
#   daemon           chay watcher inbox (log + thong bao desktop)
#   prompt           render MUSE_PROMPT.md (dán vao chat cua Agent Muse)
#   push             day bundle moi len may Muse
#   selftest         kiem tra bus hai huong (khong can mang)
# ==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_SIDE="$REPO_DIR/bridge/local_side.sh"

case "${1:-}" in
  arm)      shift; bash "$LOCAL_SIDE" arm "$@" ;;
  status)   shift; bash "$LOCAL_SIDE" status "$@" ;;
  inbox)    shift; bash "$LOCAL_SIDE" inbox "$@" ;;
  send)     shift; bash "$LOCAL_SIDE" send "$@" ;;
  ack)      shift; bash "$LOCAL_SIDE" ack "$@" ;;
  sync)     shift; bash "$LOCAL_SIDE" sync "$@" ;;
  daemon)   shift; bash "$LOCAL_SIDE" daemon "$@" ;;
  prompt)   shift; bash "$LOCAL_SIDE" prompt "$@" ;;
  push)     shift; bash "$LOCAL_SIDE" push "$@" ;;
  selftest) shift; bash "$REPO_DIR/tests/run_all.sh" ;;
  *) sed -n '2,25p' "$0"; exit 2 ;;
esac
