#!/bin/bash
# ==============================================================================
# sshd_config_guard_test.sh - Kiem tra ensure_sshd_config() trong
# bridge/reverse-tunnel.sh.
#
# Voi sao can: platform Hatch co the XOA hoac GHI DE /etc/ssh/sshd_config trong
# container. sshd khong start duoc -> hook lap lai "sshd khong tra loi banner"
# -> platform danh cell "sshd_config_invalid" + "sshd_banner_failed" ->
# flapping_backoff -> cell bi refresh (mat mot vong, chi song vai phut).
# Ban config TOT nhat duoc giu o vung ben vung (/home/hatch) de khoi phuc.
#
# Hermetic: ham duoc tai tu file that nhung duong dan duoc tro vao sandbox
# (TMP) -> khong cham /etc/ssh that, khong can container, khong can root.
# ==============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/muse-sshd-cfg.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

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
contains() { grep -q "$2" "$1"; }
lacks()    { ! grep -q "$2" "$1"; }

SSHD_BIN="$TMP/fake-sshd"
CFG="$TMP/etc/ssh/sshd_config"
SEED="$TMP/durable/sshd_config"
mkdir -p "$TMP/etc/ssh" "$TMP/durable"

# fake sshd: "-t" tra ve that neu config chua dong BROKEN
cat > "$SSHD_BIN" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-t" ]; then
  if grep -q "^BROKEN" "$TEST_CFG" 2>/dev/null; then exit 1; fi
  exit 0
fi
exit 0
EOF
chmod +x "$SSHD_BIN"
export TEST_CFG="$CFG"

# Lay dung ham tu file that, tro duong dan vao sandbox
sed -n '/^ensure_sshd_config()/,/^}/p' "$REPO_DIR/bridge/reverse-tunnel.sh" \
  | sed -e "s#/etc/ssh/sshd_config#$CFG#" \
        -e "s#/home/hatch/.muse-bridge/sshd_config#$SEED#" > "$TMP/fn.sh"
if [ ! -s "$TMP/fn.sh" ]; then
  echo "  FAIL - khong tim thay ham ensure_sshd_config trong bridge/reverse-tunnel.sh"
  exit 1
fi
# shellcheck source=/dev/null
. "$TMP/fn.sh"
log() { :; }

echo "== 1. config hop le -> snapshot vao vung ben vung, config goc khong bi doi"
printf 'Port 22\nPermitRootLogin prohibit-password\n' > "$CFG"
ensure_sshd_config
ok "seed ben vung duoc tao" contains "$SEED" 'Port 22'
ok "config goc giu nguyen" contains "$CFG" 'Port 22'

echo "== 2. config bi ghi de hong -> khoi phuc tu seed"
printf 'BROKEN config\n' > "$CFG"
ensure_sshd_config
ok "config da khoi phuc" contains "$CFG" 'Port 22'
ok "khong con config hong" lacks "$CFG" 'BROKEN'

echo "== 3. config bi xoa -> khoi phuc tu seed"
rm -f "$CFG"
ensure_sshd_config
ok "config da tao lai" contains "$CFG" 'Port 22'

echo "== 4. khong co seed + config hong -> viet config toi thieu"
rm -f "$SEED"
printf 'BROKEN config\n' > "$CFG"
ensure_sshd_config
ok "da viet config toi thieu" contains "$CFG" 'PermitRootLogin prohibit-password'
ok "config moi luu vao vung ben vung" contains "$SEED" 'Port 22'

echo "== 5. config hop le -> khong ghi de config dang co"
printf 'Port 2222\n' > "$CFG"
ensure_sshd_config
ok "config hop le bi giu nguyen" contains "$CFG" 'Port 2222'

echo "== 6. hook (inject_watchdog.py) co chua guard tuong duong"
ok "block hook co SSHD_CFG_SEED" grep -q 'SSHD_CFG_SEED' "$REPO_DIR/bridge/inject_watchdog.py"
ok "block hook co khoi phuc tu seed" grep -q 'SSHD_CFG_SEED" "$SSHD_CFG"' "$REPO_DIR/bridge/inject_watchdog.py"

echo
if [ "$fails" -eq 0 ]; then
  echo "ALL TESTS: PASS"
else
  echo "ALL TESTS: FAIL ($fails)"
fi
exit $((fails > 0))
