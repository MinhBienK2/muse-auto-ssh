#!/bin/bash
# ==============================================================================
# provision_bundle_test.sh - provision phai day bundle MOI, khong phai ban cu.
#
# Loi that (20/11): `provision` khong refresh ~/.muse-bridge/bundle va khong
# mirror vao /root/.muse-bridge/bundle/ tren container -> container pull_updates
# thay VERSION cu -> giu watchdog v6/loop v9 du repo da len v7/v10.
#
# Hermetic: ssh gia ghi lai moi lenh + stdin vao thu muc tam; HOME tam.
# ==============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/muse-provision-test.XXXXXX)"
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

export HOME="$TMP/home"
mkdir -p "$HOME/.ssh"
ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N "" -C "provision-test" >/dev/null 2>&1
export MUSE_BRIDGE_STATE="$TMP/state"
export MUSE_BRIDGE_REPO_HOSTS="$TMP/repo-hosts"
mkdir -p "$MUSE_BRIDGE_STATE/hosts" "$MUSE_BRIDGE_REPO_HOSTS"

cat > "$MUSE_BRIDGE_STATE/hosts/musetest.json" <<EOF
{
  "id": "musetest",
  "role": "local",
  "spool": "$TMP/spool",
  "peer": {"id": "musetest", "role": "muse", "transport": "ssh",
           "host": "127.0.0.1", "port": 2299, "user": "root"}
}
EOF

# ssh gia: ghi argv + stdin thanh tung ban ghi de doi chieu file duoc day.
mkdir -p "$TMP/bin" "$TMP/calls"
cat > "$TMP/bin/ssh" <<'EOF'
#!/bin/bash
n=$(ls "$CALLS_DIR" | wc -l)
printf '%s\n' "$*" > "$CALLS_DIR/$n.cmd"
cat > "$CALLS_DIR/$n.stdin"
exit 0
EOF
chmod +x "$TMP/bin/ssh"
export CALLS_DIR="$TMP/calls"
export PATH="$TMP/bin:$PATH"

# Bundle cu o state (nhu sau lan arm truoc do, repo chua sua).
mkdir -p "$MUSE_BRIDGE_STATE/bundle"
echo "OLD-VERSION" > "$MUSE_BRIDGE_STATE/bundle/VERSION"
for f in bridge.py muse_side.sh inject_watchdog.py reverse-tunnel.sh ts-socat-proxy.sh ts-connect-proxy.py; do
  echo "OLD $f" > "$MUSE_BRIDGE_STATE/bundle/$f"
done

echo "== 1. provision refresh bundle local + day ban moi len container"
out="$(bash "$REPO_DIR/scripts/bridge.sh" provision --host musetest 2>&1)"
rc=$?
# cmd_status tra exit != 0 khi PEER_STATE=DOWN (ssh gia khong co tunnel that)
# -> chi fail khi provision chua chay toi phan setup.
if grep -q "setup xong" <<<"$out"; then echo "  ok   - provision chay het phan setup (ssh gia)"; else echo "  FAIL - provision dung som (exit $rc): $out"; fails=$((fails + 1)); fi

ok "bundle local duoc refresh (VERSION khong con OLD)" \
  bash -c '! grep -q OLD-VERSION "$1/bundle/VERSION"' _ "$MUSE_BRIDGE_STATE"
ok "inject_watchdog.py local la ban repo (watchdog v9)" \
  grep -q "watchdog v9" "$MUSE_BRIDGE_STATE/bundle/inject_watchdog.py"

# Moi ban ghi ssh co chua 'cat > /root/.muse-bridge/bundle/<f>' phai mang dung
# noi dung bundle local (ban moi), khong phai OLD.
code=0
python3 - "$CALLS_DIR" "$MUSE_BRIDGE_STATE/bundle" <<'PY' || code=$?
import os, sys
calls, bundle = sys.argv[1], sys.argv[2]
seen = set()
for name in sorted(os.listdir(calls)):
    if not name.endswith(".cmd"):
        continue
    cmd = open(os.path.join(calls, name)).read()
    stdin = open(os.path.join(calls, name[:-4] + ".stdin"), "rb").read()
    marker = "cat > /root/.muse-bridge/bundle/"
    if marker not in cmd:
        continue
    fname = cmd.split(marker)[1].split()[0].strip("'\"")
    seen.add(fname)
    want = open(os.path.join(bundle, fname), "rb").read()
    assert stdin == want, "bundle/%s day sai noi dung (ban cu?)" % fname
need = {"bridge.py", "muse_side.sh", "inject_watchdog.py", "reverse-tunnel.sh",
        "ts-socat-proxy.sh", "ts-connect-proxy.py", "VERSION"}
assert need <= seen, "thieu file trong bundle mirror: %s" % (need - seen)
PY
if [ "$code" = "0" ]; then
  echo "  ok   - bundle/ container nhan du 7 file, dung noi dung ban moi"
else
  echo "  FAIL - bundle mirror thieu/sai noi dung"
  fails=$((fails + 1))
fi

echo
if [ "$fails" = "0" ]; then echo "PROVISION_BUNDLE_TEST: PASS"; else echo "PROVISION_BUNDLE_TEST: FAIL ($fails)"; fi
exit "$fails"