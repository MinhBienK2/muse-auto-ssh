#!/bin/bash
# ==============================================================================
# run_all.sh - chay toan bo kiem tra cua repo (khong can mang).
#
#   bash tests/run_all.sh            # chay thuong
#   bash tests/run_all.sh --strict   # CI: thieu shellcheck/ruff thi FAIL
#
# --strict dung cho CI: moi thieu cong cu kiem tra (shellcheck/ruff) co the
# bo qua, thieu tool thi phai fail thay vi im lang bo qua.
# ==============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR" || exit 1

STRICT=0
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    *) echo "usage: run_all.sh [--strict]" >&2; exit 2 ;;
  esac
done

fails=0
skip() {  # skip <ten> <ly-do>
  if [ "$STRICT" = "1" ]; then
    echo "  FAIL - thieu $1 ($2)"
    fails=$((fails + 1))
  else
    echo "  skip - thieu $1 ($2)"
  fi
}

for t in bus_selftest.sh watchdog_upgrade_test.sh muse_side_test.sh hosts_test.sh; do
  [ -f "$REPO_DIR/tests/$t" ] || continue
  echo "=============================================================="
  echo "== $t"
  echo "=============================================================="
  bash "$REPO_DIR/tests/$t" || fails=$((fails + 1))
  echo
done

# tests/selfheal_test.sh la test THAT (can container Muse that + can SSH that)
# -> khong chay trong bo offline nay. Chay tay: bash tests/selfheal_test.sh --host <id>

echo "== check_prompt_sync.sh"
if [ "$STRICT" = "1" ]; then
  bash "$REPO_DIR/scripts/check_prompt_sync.sh" --strict || fails=$((fails + 1))
else
  bash "$REPO_DIR/scripts/check_prompt_sync.sh" || fails=$((fails + 1))
fi
echo

echo "== check_hygiene.sh"
bash "$REPO_DIR/scripts/check_hygiene.sh" || fails=$((fails + 1))
echo

echo "== bash -n tat ca script shell"
while IFS= read -r f; do
  bash -n "$f" || { echo "  FAIL syntax: $f"; fails=$((fails + 1)); }
done < <(find "$REPO_DIR/bridge" "$REPO_DIR/scripts" "$REPO_DIR/tests" -name '*.sh')
echo "  ok - syntax shell"
echo

echo "== shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  sc_out="$(shellcheck -S warning -x "$REPO_DIR"/bridge/*.sh "$REPO_DIR"/scripts/*.sh "$REPO_DIR"/tests/*.sh 2>&1)" \
    && echo "  ok - shellcheck" \
    || { echo "$sc_out"; echo "  FAIL - shellcheck"; fails=$((fails + 1)); }
else
  skip "shellcheck" "cai: pip install shellcheck-py"
fi
echo

echo "== ruff"
if command -v ruff >/dev/null 2>&1; then
  ruff_out="$(cd "$REPO_DIR" && ruff check bridge/*.py scripts/*.py 2>&1)" \
    && echo "  ok - ruff" \
    || { echo "$ruff_out"; echo "  FAIL - ruff"; fails=$((fails + 1)); }
else
  skip "ruff" "cai: pip install ruff"
fi
echo

if [ "$fails" = "0" ]; then
  echo "ALL TESTS: PASS"
else
  echo "ALL TESTS: FAIL ($fails)"
fi
exit "$fails"
