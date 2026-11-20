#!/bin/bash
# ==============================================================================
# strict_modes_test.sh - Chong hoi quy ve dung symlink cho authorized_keys.
#
# Van de goc (kiem chung tren container that):
#   /home/hatch la group-writable (drwxrws---) -> sshd bat StrictModes se TU CHOI
#   key nam trong thu muc do -> Permission denied (publickey,password).
# Da co noi dung (prompt, MUSE_AGENT.md, AGENTS.md, README.md, PROTOCOL.md,
# local_side.sh) noi "nen tao symlink" -> sai, se lam hong container moi.
#
# Hermetic: chi doc file trong repo.
# ==============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

# File nao duoc doc bai Agent Muse hoac người dùng -> phai noi COPY, khong noi symlink.
DOCS=(
  ".agents/setup-ssh-muse/reference/MUSE_PROMPT.template.md"
  "MUSE_AGENT.md"
  "AGENTS.md"
  "README.md"
  "PROTOCOL.md"
)

echo "== 1. tai lieu khong con 'nen tao symlink' cho authorized_keys"
# Chi phan loai khi tai lieu "khuyen" tao symlink. Cau co "KHONG/Không ... symlink"
# (canh bao) van duoc phep.
for d in "${DOCS[@]}"; do
  [ -f "$REPO_DIR/$d" ] || continue
  bad=0
  while IFS= read -r line; do
    # bo qua dong da canh bao "khong dung symlink"
    if printf '%s' "$line" | grep -qiE "kh(ô|o|o)ng.{0,30}symlink|do not use symlink"; then
      continue
    fi
    printf '%s' "$line" | grep -qiE "symlink.{0,80}authorized_keys|authorized_keys.{0,80}symlink" && bad=1
  done < "$REPO_DIR/$d"
  if [ "$bad" = "1" ]; then
    echo "  FAIL - $d van bao tao symlink cho authorized_keys"
    fails=$((fails + 1))
  else
    echo "  ok   - $d"
  fi
done

echo "== 2. prompt template dung cp (khong ln -sf) cho authorized_keys"
ok "prompt dung cp -f" \
  grep -q "cp -f /home/hatch/.ssh/authorized_keys /root/.ssh/authorized_keys" \
  "$REPO_DIR/.agents/setup-ssh-muse/reference/MUSE_PROMPT.template.md"
ok "prompt khong dung ln -sf cho authorized_keys" \
  bash -c '! grep -q "ln -sf /home/hatch/.ssh/authorized_keys" "$1"' \
  _ "$REPO_DIR/.agents/setup-ssh-muse/reference/MUSE_PROMPT.template.md"

echo "== 3. local_side.sh (repair) copy key tu seed, khong tao symlink"
ok "repair dung cp -f tu seed" \
  grep -q "cp -f \"\$SEED\" /root/.ssh/authorized_keys" "$REPO_DIR/bridge/local_side.sh"
ok "repair khong tao symlink authorized_keys" \
  bash -c '! grep -q "ln -sfn /home/hatch/.ssh/authorized_keys" "$1"' \
  _ "$REPO_DIR/bridge/local_side.sh"

echo "== 4. container-side scripts cung copy, khong symlink"
for f in bridge/reverse-tunnel.sh bridge/muse_side.sh; do
  ok "$f khong symlink authorized_keys sang /home/hatch" \
    bash -c '! grep -qE "ln -sfn? /home/hatch/.ssh/authorized_keys" "$1"' _ "$REPO_DIR/$f"
done

echo "== 5. bus (symlink /root/.muse-bridge) van duoc phep - sshd khong doc file nay"
ok "muse_side.sh van symlink bus sang vung ben vung" \
  grep -q 'ln -sfn "\$persistent" "\$STATE_DIR"' "$REPO_DIR/bridge/muse_side.sh"

echo
if [ "$fails" = "0" ]; then echo "STRICT_MODES_TEST: PASS"; else echo "STRICT_MODES_TEST: FAIL ($fails)"; fi
exit "$fails"
