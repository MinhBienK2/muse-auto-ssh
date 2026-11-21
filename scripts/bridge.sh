#!/bin/bash
# ==============================================================================
# bridge.sh - CLI phia may ngoai (Agent Ngoai goi lenh nay).
#
#   hosts                      danh sach cac Muse host da dang ky
#   profiles                   liet ke Chrome profile + profile nao con dang nhap muse.ai
#                              [--json]  (agent dung de hoi user chon profile)
#   add-host --host <id>       dang ky Muse host moi (port, ssh alias, spool)
#                              [--profile-dir "Profile 2"]  <- Chrome profile/account
#   set-port --host <id> --port <p>  doi port host da dang ky (khong ghi lai card)
#   rename --host <id> --new-id <id-moi>  doi ten host theo chuan muse-<email>
#   remove-host --host <id>    go dang ky host (giu spool + lich su card .removed/)
#   onboard --host <id>       \x{1}trong suot: dang ky -> gui prompt qua web Muse -> xac nhan
#   chat --host <id>          chat rieng cua bridge cho host (tao neu chua co, luu vao card)
#   arm --host <id>            chuan bi moi truong may ngoai (idempotent)
#   status --host <id>         trang thai kenh hai chieu
#   inbox --host <id>          doc tin nhan gui tu Muse
#   send --host <id> --type .. gui tin nhan cho Muse
#   ack --host <id> <id>       danh dau da xu ly
#   sync --host <id>           gui lai cac tin choang gui (pending)
#   pull --host <id>           keo tin tu peer (khi chi con 1 chieu)
#   daemon --host <id>         watcher inbox (log + thong bao desktop)
#   prompt --host <id>         render prompt cho host do (PROMPT DUY NHAT cua repo)
#                              [--print] [--clip] [--send]
#                              (--send dan prompt vao web Muse va CHO doi den khi
#                               Muse bao status block - co the treo toi ~10 phút)
#   push --host <id>           day bundle moi len host do
#   provision --host <id>      day bus + watchdog + chay setup phia container
#   reprovision --host <id>    provision lai (bus bi mat sau khi container refresh)
#   repair --host <id>         danh thuc container Muse bi dong bang qua web
#   authorize --host <id> --key '<ssh-ed25519 ...>'  them key cua Muse
#   doctor                     chan doan trang thai (forward, keepalive, key)
#   release --host <id>        dung session ssh cu giu port forward (container treo)
#   selftest                   kiem tra bus hai huong (khong can mang)
# ==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_SIDE="$REPO_DIR/bridge/local_side.sh"

case "${1:-}" in
  hosts)     shift; bash "$LOCAL_SIDE" hosts "$@" ;;
  profiles)  shift; bash "$LOCAL_SIDE" profiles "$@" ;;
  doctor)    shift; bash "$LOCAL_SIDE" doctor "$@" ;;
  release)   shift; bash "$LOCAL_SIDE" release "$@" ;;
  add-host)  shift; bash "$LOCAL_SIDE" add-host "$@" ;;
  set-port)  shift; bash "$LOCAL_SIDE" set-port "$@" ;;
  rename)    shift; bash "$LOCAL_SIDE" rename "$@" ;;
  remove-host) shift; bash "$LOCAL_SIDE" remove-host "$@" ;;
  onboard)   shift; bash "$LOCAL_SIDE" onboard "$@" ;;
  chat)      shift; bash "$LOCAL_SIDE" chat "$@" ;;
  provision) shift; bash "$LOCAL_SIDE" provision "$@" ;;
  repair)    shift; bash "$LOCAL_SIDE" repair "$@" ;;
  reprovision) shift; bash "$LOCAL_SIDE" reprovision "$@" ;;
  arm)       shift; bash "$LOCAL_SIDE" arm "$@" ;;
  status)    shift; bash "$LOCAL_SIDE" status "$@" ;;
  inbox)     shift; bash "$LOCAL_SIDE" inbox "$@" ;;
  send)      shift; bash "$LOCAL_SIDE" send "$@" ;;
  ack)       shift; bash "$LOCAL_SIDE" ack "$@" ;;
  sync)      shift; bash "$LOCAL_SIDE" sync "$@" ;;
  pull)      shift; bash "$LOCAL_SIDE" pull "$@" ;;
  daemon)    shift; bash "$LOCAL_SIDE" daemon "$@" ;;
  prompt)    shift; bash "$LOCAL_SIDE" prompt "$@" ;;
  push)      shift; bash "$LOCAL_SIDE" push "$@" ;;
  authorize) shift; bash "$LOCAL_SIDE" authorize "$@" ;;
  selftest)  shift; bash "$REPO_DIR/tests/run_all.sh" ;;
  *) sed -n '2,32p' "$0"; exit 2 ;;
esac
