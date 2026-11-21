#!/bin/bash
# ==============================================================================
# autodeploy_test.sh - Kiem tra auto_deploy_bundle() (bridge/local_side.sh).
#
# Ly do can test: container Muse CHI chay code ma may ngoai day. Commit xong
# ma quen `bridge.sh push` -> container van chay ban cu (loop v9, hook v6).
# Khi platform pause session agent, loop chet theo -> cell mat SSH ~45 phut.
# Day la nguyên nhân gốc của các đợt "cell chết lâu".
#
# Quy tac an toan: CHI deploy khi HEAD doi VA cay git SACH (khong deploy ban
# dang soan). TAT bang MUSE_AUTO_DEPLOY=0.
#
# Hermetic: ham duoc tach tu file that, bien phu thuoc bi stub trong sandbox.
# ==============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/muse-autodeploy-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fails=0
check() { if [ "$2" = "0" ]; then echo "  ok   - $1"; else echo "  FAIL - $1"; fails=$((fails+1)); fi; }

# Lay ham tu file that (co thut trong cmd_daemon) -> tro duong dan vao sandbox
sed -n '/^auto_deploy_bundle()/,/^}/p' "$REPO_DIR/bridge/local_side.sh" > "$TMP/fn.sh"
if ! grep -q "auto_deploy_bundle()" "$TMP/fn.sh"; then
  echo "  FAIL - khong tach duoc auto_deploy_bundle tu local_side.sh"
  echo "AUTODEPLOY_TEST: FAIL (1)"
  exit 1
fi

# --- stubs -------------------------------------------------------------------
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/git" <<EOF
#!/bin/bash
case "\$*" in
  *"rev-parse HEAD"*) echo "\${FAKE_HEAD:-head-1}" ;;
  *"status --porcelain"*) [ -n "\${FAKE_DIRTY:-}" ] && echo " M bridge/x.sh" ;;
  *) : ;;
esac
exit 0
EOF
chmod +x "$STUB/git"

cat > "$TMP/run.sh" <<'EOF'
set -u
TMP="${TEST_TMP:?}"
STATE_DIR="$TMP/state"
REPO_DIR="$TMP/repo"
HOST="muse-test"
mkdir -p "$STATE_DIR" "$REPO_DIR"
export STATE_DIR REPO_DIR HOST
say() { printf '%s\n' "$*"; }
install_bundle_local() { printf 'install\n' >> "$TMP/calls"; }
host_ids() { printf 'h1\nh2\n'; }
host_peer_port() { case "$1" in h1) echo 2222 ;; h2) echo 2225 ;; esac; }
host_reachable() { [ "${1:-}" = "2222" ]; }
push_bundle() { printf 'push %s\n' "$1" >> "$TMP/calls"; }
. "$TMP/fn.sh"
auto_deploy_bundle
EOF

run_case() {  # run_case <label> <expect: deploy|nodeploy> [env...]
  local label="$1" expect="$2"; shift 2
  : > "$TMP/calls"
  rm -rf "$TMP/state"; mkdir -p "$TMP/state"
  local out
  out="$(env PATH="$STUB:$PATH" TEST_TMP="$TMP" "$@" bash "$TMP/run.sh" 2>&1)"
  if [ "$expect" = "deploy" ]; then
    if grep -q '^install$' "$TMP/calls" && grep -q '^push 2222$' "$TMP/calls"; then
      check "$label" 0
    else
      check "$label" 1
      printf '        calls=%s out=%s\n' "$(tr '\n' ' ' < "$TMP/calls")" "$out"
    fi
    # host khong phan hoi (2225) -> khong push
    if grep -q '^push 2225$' "$TMP/calls"; then
      echo "  FAIL - $label (push ca host khong phan hoi)"; fails=$((fails+1))
    fi
  else
    if [ -s "$TMP/calls" ]; then
      check "$label" 1
      printf '        calls=%s\n' "$(tr '\n' ' ' < "$TMP/calls")"
    else
      check "$label" 0
    fi
  fi
  return 0
}

# 1) HEAD moi + cay git sach -> phai deploy
run_case "HEAD moi + cay sach -> deploy bundle" deploy FAKE_HEAD=head-2 FAKE_DIRTY=""

# 2) cay git dang soan -> KHONG deploy (tranh day ban vung lam container chet)
run_case "cay git dang soan -> khong deploy" nodeploy FAKE_HEAD=head-3 FAKE_DIRTY=1

# 3) MUSE_AUTO_DEPLOY=0 -> KHONG deploy
run_case "MUSE_AUTO_DEPLOY=0 -> khong deploy" nodeploy FAKE_HEAD=head-4 MUSE_AUTO_DEPLOY=0

# 4) HEAD da deploy roi -> khong deploy lai (khong spam)
: > "$TMP/calls"
mkdir -p "$TMP/state"; printf 'head-5\n' > "$TMP/state/.deployed_head"
out="$(env PATH="$STUB:$PATH" TEST_TMP="$TMP" FAKE_HEAD=head-5 bash "$TMP/run.sh" 2>&1)"
if [ -s "$TMP/calls" ]; then
  check "HEAD da deploy -> khong deploy lai" 1
else
  check "HEAD da deploy -> khong deploy lai" 0
fi

echo
if [ "$fails" = "0" ]; then echo "AUTODEPLOY_TEST: PASS"; else echo "AUTODEPLOY_TEST: FAIL ($fails)"; fi
exit "$fails"
