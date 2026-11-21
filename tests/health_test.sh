#!/bin/bash
# ==============================================================================
# health_test.sh - kiem tra `bridge.sh health`: lay mau, dem restart, phat hien
# container DOWN.
#
#   1. Mau duoc ghi vao <state>/health/<id>/samples.jsonl
#   2. boot_id doi  = dem duoc 1 lan restart
#   3. Khong noi duoc container = state DOWN + dem duoc 1 lan outage
#   4. So tin trong spool local duoc dem dung
#
# Hermetic: HOME tam, ssh gia (khong cham container that).
# ==============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/muse-health-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
mkdir -p "$HOME/.ssh"
ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N "" -C "muse-health-test" >/dev/null 2>&1
export MUSE_BRIDGE_STATE="$TMP/state"
export MUSE_BRIDGE_REPO_HOSTS="$TMP/repo-hosts"
export MUSE_BRIDGE_HEALTH_DIR="$TMP/state/health"

HOST_ID="muse-test"
PORT=2299
SPOOL="$TMP/state/spools/$HOST_ID"
mkdir -p "$SPOOL"/{inbox,outbox,pending,read}
printf '{}\n' > "$SPOOL/inbox/a.json"
printf '{}\n' > "$SPOOL/inbox/b.json"
printf '{}\n' > "$SPOOL/outbox/c.json"

mkdir -p "$MUSE_BRIDGE_STATE/hosts"
cat > "$MUSE_BRIDGE_STATE/hosts/$HOST_ID.json" <<EOF
{
  "id": "$HOST_ID",
  "role": "local",
  "spool": "$SPOOL",
  "peer": {
    "id": "$HOST_ID",
    "role": "muse",
    "transport": "ssh",
    "host": "127.0.0.1",
    "port": $PORT,
    "user": "root",
    "spool": "/root/.muse-bridge"
  }
}
EOF

# ssh gia: doc JSON peer tu file; khong co file -> exit 255 (container DOWN)
mkdir -p "$TMP/bin"
cat > "$TMP/bin/ssh" <<'EOF'
#!/bin/bash
if [ -f "$FAKE_PEER_JSON" ]; then cat "$FAKE_PEER_JSON"; exit 0; fi
cat >/dev/null 2>&1 || true
exit 255
EOF
chmod +x "$TMP/bin/ssh"
export PATH="$TMP/bin:$PATH"
export FAKE_PEER_JSON="$TMP/peer.json"

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

PEER_A='{"boot_id":"boot-a","uptime_s":600,"mem_available_mb":700,"disk_free_mb":7000,"durable":"/home/hatch","peer_inbox":5,"peer_outbox":0,"peer_pending":0,"peer_read":0,"sshd":"running","tunnel":1}'
PEER_B='{"boot_id":"boot-b","uptime_s":30,"mem_available_mb":650,"disk_free_mb":6900,"durable":"/home/hatch","peer_inbox":5,"peer_outbox":0,"peer_pending":0,"peer_read":0,"sshd":"running","tunnel":1}'

echo "== 1. lay mau lan 1 (container UP)"
printf '%s' "$PEER_A" > "$FAKE_PEER_JSON"
out="$(bash "$REPO_DIR/scripts/bridge.sh" health --host "$HOST_ID" 2>&1)"
code=$?
if [ "$code" = "0" ] && printf '%s' "$out" | grep -q "$HOST_ID"; then
  echo "  ok   - lenh health chay duoc va in bang"
else
  echo "  FAIL - lenh health chay duoc va in bang"; fails=$((fails + 1)); echo "$out" | sed 's/^/       /'
fi
samples="$MUSE_BRIDGE_HEALTH_DIR/$HOST_ID/samples.jsonl"
ok "mau duoc ghi vao samples.jsonl" test -s "$samples"
ok "bang co cot RESTART" bash -c "printf '%s' \"\$1\" | grep -q RESTART" _ "$out"
if printf '%s' "$out" | grep -qE '^muse-test +UP +10m'; then
  echo "  ok   - uptime 600s hien thi 10m"
else
  echo "  FAIL - uptime 600s hien thi 10m"; fails=$((fails + 1))
fi

echo "== 2. mau lan 2 voi boot_id moi -> dem duoc 1 restart"
printf '%s' "$PEER_B" > "$FAKE_PEER_JSON"
out2="$(bash "$REPO_DIR/scripts/bridge.sh" health --host "$HOST_ID" 2>&1)"
if printf '%s' "$out2" | grep -qE '^muse-test +UP +0m +1 '; then
  echo "  ok   - restart = 1"
else
  echo "  FAIL - restart = 1"; fails=$((fails + 1)); echo "$out2" | sed 's/^/       /'
fi
lines="$(wc -l < "$samples")"
if [ "$lines" -ge 2 ]; then
  echo "  ok   - samples.jsonl co >= 2 dong"
else
  echo "  FAIL - samples.jsonl co >= 2 dong"; fails=$((fails + 1))
fi

echo "== 3. container DOWN -> state DOWN + dem outage"
rm -f "$FAKE_PEER_JSON"
out3="$(bash "$REPO_DIR/scripts/bridge.sh" health --host "$HOST_ID" 2>&1)"
if printf '%s' "$out3" | grep -qE '^muse-test +DOWN'; then
  echo "  ok   - state DOWN"
else
  echo "  FAIL - state DOWN"; fails=$((fails + 1)); echo "$out3" | sed 's/^/       /'
fi
if printf '%s' "$out3" | grep -q 'down=1 lan'; then
  echo "  ok   - dem duoc 1 lan outage"
else
  echo "  FAIL - dem duoc 1 lan outage"; fails=$((fails + 1))
fi

echo "== 4. dem tin trong spool local"
printf '%s' "$PEER_A" > "$FAKE_PEER_JSON"
out4="$(bash "$REPO_DIR/scripts/bridge.sh" health --host "$HOST_ID" --json 2>&1)"
if printf '%s' "$out4" | grep -q '"local_inbox": 2'; then
  echo "  ok   - local_inbox = 2"
else
  echo "  FAIL - local_inbox = 2"; fails=$((fails + 1)); echo "$out4" | head -40 | sed 's/^/       /'
fi
if printf '%s' "$out4" | grep -q '"local_outbox": 1'; then
  echo "  ok   - local_outbox = 1"
else
  echo "  FAIL - local_outbox = 1"; fails=$((fails + 1))
fi

echo "== 5. probe chay duoc trong container (bash -n + shellcheck)"
ok "health_probe.sh parse duoc" bash -n "$REPO_DIR/bridge/health_probe.sh"
out5="$(bash "$REPO_DIR/bridge/health_probe.sh" 2222 2>/dev/null)"
if printf '%s' "$out5" | grep -q '"boot_id"'; then
  echo "  ok   - health_probe.sh in JSON"
else
  echo "  FAIL - health_probe.sh in JSON"; fails=$((fails + 1)); echo "$out5" | sed 's/^/       /'
fi

if [ "$fails" = "0" ]; then
  echo "HEALTH TEST: PASS"
else
  echo "HEALTH TEST: FAIL ($fails)"
fi
exit "$fails"
