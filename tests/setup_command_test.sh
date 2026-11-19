#!/bin/bash
# ==============================================================================
# setup_command_test.sh - Kiem tra skill /setup-ssh-muse
# (.claude/skills/setup-ssh-muse/SKILL.md).
#
# Voi sao can: skill nay la "hop dong" giua nguoi dung, agent ngoai va may Muse:
#   agent -> hoi cau hoi -> sinh setup_prompt.md -> DUNG cho user paste ->
#   user paste status block cua Muse -> agent setup tiep -> ssh <alias> vao duoc.
# Neu skill rot (thieu chang, thieu lenh, thieu ten bien) thi ca luong vo.
#
# Hermetic: chi doc file trong repo, khong can mang / container.
# ==============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CMD="$REPO_DIR/.claude/skills/setup-ssh-muse/SKILL.md"
TPL="$REPO_DIR/templates/MUSE_ONESHOT.template.md"

fails=0
ok() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  ok   - $label"
  else
    echo "  FAIL - $label"
    fails=$((fails + 1))
  fi
}
has()     { grep -qF -- "$2" "$1"; }
lacks()   { ! grep -qF -- "$2" "$1"; }
has_re()  { grep -qE -- "$2" "$1"; }

if [ ! -f "$CMD" ]; then
  echo "  FAIL - khong tim thay $CMD"
  exit 1
fi

echo "== 1. frontmatter dung chuan skill"
ok "co frontmatter --- o dau file"   head -1 "$CMD" | grep -qF -- '---'
ok "co name"                         has "$CMD" "name: setup-ssh-muse"
ok "co description"                  has "$CMD" "description:"
ok "co argument-hint"                has "$CMD" "argument-hint:"
ok "co allowed-tools"                has "$CMD" "allowed-tools:"
ok "allowed-tools co AskUserQuestion (phai hoi duoc user)" \
  has_re "$CMD" '^allowed-tools:.*AskUserQuestion'

echo "== 2. co du 7 chang A..G"
for c in "Chặng A" "Chặng B" "Chặng C" "Chặng D" "Chặng E" "Chặng F" "Chặng G"; do
  ok "co $c" has "$CMD" "$c"
done

echo "== 3. dung lenh repo (khong tu che lenh)"
for cmd in "bridge.sh arm" "bridge.sh add-host" "bridge.sh set-port" "bridge.sh oneshot" \
           "bridge.sh authorize" "bridge.sh provision" "bridge.sh status" "bridge.sh doctor" \
           "bridge.sh selftest" "bridge.sh prompt" "bridge.sh onboard"; do
  ok "co lenh '$cmd'" has "$CMD" "$cmd"
done
ok "doi port bang set-port, khong chay lai add-host" \
  has_re "$CMD" 'set-port.*--port'

echo "== 4. setup_prompt.md: sinh ra + gitignore"
ok "command tao setup_prompt.md"   has "$CMD" "setup_prompt.md"
ok "setup_prompt.md trong .gitignore" has "$REPO_DIR/.gitignore" "setup_prompt.md"

echo "== 5. status block: 7 bien, ten giong het template"
for f in MUSE_HOST MUSE_KEY MUSE_PUBKEY MUSE_TUNNEL_PORT MUSE_TUNNEL MUSE_PERSISTENCE MUSE_PROBE; do
  ok "command biet '$f'" has "$CMD" "$f"
  ok "template co '$f'" has "$TPL" "$f"
done
n="$(grep -cE '^MUSE_[A-Z_]+=' "$TPL")"
ok "template co du 7 dong KEY=value (hien tai $n)" bash -c '[ "$1" = 7 ]' _ "$n"

echo "== 6. co buoc 'dung cho user paste' (khong tu doan)"
ok "command co quy tac DUNG"       has_re "$CMD" 'DỪNG|DUNG\.'
ok "command noi ro phai paste"     has_re "$CMD" 'paste'
ok "command co nhan --resume"      has "$CMD" "--resume"
ok "command luu trang thai phien"  has "$CMD" "setup_state.json"
ok "state co phase de resume"      has_re "$CMD" 'phase'
ok "state ghi ngay khi hoi xong"   has_re "$CMD" 'asked'
ok "state co phase waiting_muse"   has "$CMD" "waiting_muse"
ok "truong hop Chrome profile"     has "$CMD" "--profile-dir"

echo "== 7. xac nhan cuoi bang ssh <alias>"
ok "command co kiem tra SSH_OK"    has "$CMD" "SSH_OK"

echo
if [ "$fails" -eq 0 ]; then
  echo "ALL TESTS: PASS"
else
  echo "ALL TESTS: FAIL ($fails)"
fi
exit $((fails > 0))
