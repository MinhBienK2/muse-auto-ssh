#!/bin/bash
# ==============================================================================
# run_all.sh - chay toan bo kiem tra cua repo (khong can mang).
# ==============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0

for t in bus_selftest.sh watchdog_upgrade_test.sh muse_side_test.sh; do
  echo "=============================================================="
  echo "== $t"
  echo "=============================================================="
  bash "$REPO_DIR/tests/$t" || fails=$((fails+1))
  echo
done

echo "== check_prompt_sync.sh"
bash "$REPO_DIR/scripts/check_prompt_sync.sh" || fails=$((fails+1))
echo

echo "== bash -n tat ca script shell"
while IFS= read -r f; do
  bash -n "$f" || { echo "  FAIL syntax: $f"; fails=$((fails+1)); }
done < <(find "$REPO_DIR/bridge" "$REPO_DIR/scripts" "$REPO_DIR/tests" -name '*.sh')
echo "  ok - syntax shell"
echo

if [ "$fails" = "0" ]; then
  echo "ALL TESTS: PASS"
else
  echo "ALL TESTS: FAIL ($fails)"
fi
exit "$fails"
