#!/bin/bash
# ==============================================================================
# prompt_test.sh - Kiem tra PROMPT DUY NHAT cua repo (nam trong skill
# .agents/setup-ssh-muse/reference/MUSE_PROMPT.template.md).
#
#   1. Render duoc, khong con placeholder, khong nhung source code bus.
#   2. Co du 7 buoc + noi dung bat buoc (proxy, keo bundle, systemd, status block).
#   3. Moi khoi bash trong prompt parse duoc (bash -n) va proxy helper python
#      compile duoc -> prompt dán vao chat la chay duoc ngay.
#   4. Template khong chua gia tri rieng cua may nao (IP, duong dan home).
#   5. bridge.sh prompt render dung file cho host.
#   6. Repo khong con prompt thu hai (khong con file short/oneshot khac).
#
# Hermetic: HOME tam, tailscale gia (khong doc trang thai that cua may).
# ==============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/muse-prompt-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
mkdir -p "$HOME/.ssh"
ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N "" -C "muse-prompt-test" >/dev/null 2>&1
export MUSE_BRIDGE_STATE="$TMP/state"
export MUSE_BRIDGE_REPO_HOSTS="$TMP/repo-hosts"
export MUSE_URL="https://muse.ai/"

# tailscale gia -> khong doc trang thai that cua may (luat test hermetic)
mkdir -p "$TMP/bin"
cat > "$TMP/bin/tailscale" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "ip" ]; then echo "100.64.0.1"; exit 0; fi
exit 1
EOF
chmod +x "$TMP/bin/tailscale"
export PATH="$TMP/bin:$PATH"

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

rc() {
  if [ "$2" = "0" ]; then
    echo "  ok   - $1"
  else
    echo "  FAIL - $1"
    fails=$((fails + 1))
  fi
}

TEMPLATE="$REPO_DIR/.agents/setup-ssh-muse/reference/MUSE_PROMPT.template.md"
PROMPT="$TMP/MUSE_PROMPT.md"

echo "== 1. render prompt"
code=0
python3 "$REPO_DIR/scripts/render_prompt.py" \
  --host 100.64.0.1 --user testuser --pubkey "ssh-ed25519 AAAAPROBE" \
  --port 2225 --spool "$TMP/spool" --host-id muse4 --hostname probehost \
  --bundle-dir "$TMP/bundle" --out "$PROMPT" >/dev/null || code=$?
rc "render_prompt.py chay duoc" "$code"
ok "file prompt co noi dung" test -s "$PROMPT"
ok "khong con placeholder" bash -c '! grep -q "{{[A-Z0-9_]*}}" "$1"' _ "$PROMPT"
size=$(wc -c < "$PROMPT")
ok "prompt khong qua dai (<18000 B, hien tai ${size}B)" test "$size" -lt 18000
ok "khong nhung source code bus" \
  bash -c '! grep -qE "MUSE_BRIDGE_PY_EOF|MUSE_SIDE_SH_EOF|MUSE_INJECT_WD_EOF" "$1"' _ "$PROMPT"

echo "== 2. noi dung bat buoc co trong prompt"
for needle in "Bước 1" "Bước 2" "Bước 3" "Bước 4" "Bước 5" "Bước 6" "Bước 7" \
               "Không hỏi tôi" "DIRECT_OK" "MUSE_PROBE" "Restart=always" \
               "hatch-egress-proxy:3130" "authorized_keys" "tar cf -" "ts-proxy.py" \
               "2225" "100.64.0.1" "testuser" "AAAAPROBE" "muse4"; do
  ok "co '$needle'" grep -q -- "$needle" "$PROMPT"
done

echo "== 3. khoi bash trong prompt parse duoc"
code=0
python3 - "$PROMPT" "$TMP" <<'PY' || code=$?
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
blocks = re.findall(r"```bash\n(.*?)```", text, re.S)
for i, block in enumerate(blocks):
    with open("%s/blk_%02d.sh" % (sys.argv[2], i), "w", encoding="utf-8") as fh:
        fh.write(block)
print("blocks=%d" % len(blocks))
PY
rc " tach cac khoi bash" "$code"
for blk in "$TMP"/blk_*.sh; do
  [ -f "$blk" ] || continue
  ok "bash -n $(basename "$blk")" bash -n "$blk"
done

echo "== 4. proxy helper python trong prompt compile duoc"
code=0
python3 - "$PROMPT" "$TMP/ts-proxy.py" <<'PY' || code=$?
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"<<'PYEOF'\n(.*?)\nPYEOF", text, re.S)
if not m:
    sys.exit(1)
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    fh.write(m.group(1))
PY
rc "tach duoc proxy helper" "$code"
ok "proxy helper hop le python" python3 -m py_compile "$TMP/ts-proxy.py"

echo "== 5. template khong chua gia tri rieng cua may"
ok "template khong chua IP that" bash -c '
  ! grep -nE "[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}" "$1" \
    | grep -vE "\b(127|0|255)\." | grep -vE "\b(10|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\." \
    | grep -vE "\b100\.(64|100|115|126|127)\."
' _ "$TEMPLATE"
ok "template khong chua duong dan home rieng" bash -c '
  ! grep -nE "/home/[a-z][a-z0-9._-]+/" "$1" | grep -vE "/home/(hatch|root|user)/"
' _ "$TEMPLATE"

echo "== 6. bridge.sh prompt render dung file cho host"
bash "$REPO_DIR/scripts/bridge.sh" add-host --host muse4 --port 2225 >/dev/null 2>&1
code=0
bash "$REPO_DIR/scripts/bridge.sh" prompt --host muse4 >/dev/null 2>&1 || code=$?
rc "bridge.sh prompt chay duoc" "$code"
PROMPT_FILE="$MUSE_BRIDGE_REPO_HOSTS/muse4/MUSE_PROMPT.md"
ok "da render MUSE_PROMPT.md cho host" test -s "$PROMPT_FILE"
ok "file chua port cua host" grep -q "2225" "$PROMPT_FILE"
ok "file chua host id" grep -q "muse4" "$PROMPT_FILE"

echo "== 7. repo chi con MOT prompt"
ok "khong con thu muc templates/" bash -c '! test -d "$1/templates"' _ "$REPO_DIR"
ok "template nam trong .agents/" test -f "$TEMPLATE"
ok "khong con file MUSE_ONESHOT.template.md" \
  bash -c '! find "$1" -name "MUSE_ONESHOT.template.md" -not -path "*/.git/*" | grep -q .' _ "$REPO_DIR"
ok "khong con lenh 'bridge.sh oneshot'" \
  bash -c '! grep -qE "^[[:space:]]*oneshot\)" "$1/scripts/bridge.sh"' _ "$REPO_DIR"

echo "== 8. proxy helper python: mot ban goc duy nhat"
ok "helper trong repo compile duoc" python3 -m py_compile "$REPO_DIR/bridge/ts-connect-proxy.py"
code=0
python3 - "$REPO_DIR/bridge/ts-connect-proxy.py" "$PROMPT" <<'PY' || code=$?
import re, sys
repo = open(sys.argv[1], encoding="utf-8").read().rstrip("\n")
text = open(sys.argv[2], encoding="utf-8").read()
m = re.search(r"<<'PYEOF'\n(.*?)\nPYEOF", text, re.S)
if not m or m.group(1).rstrip("\n") != repo:
    sys.exit(1)
PY
rc "helper trong prompt == bridge/ts-connect-proxy.py" "$code"
ok "ts-socat-proxy.sh co fallback sang python" \
  grep -q "ts-connect-proxy.py" "$REPO_DIR/bridge/ts-socat-proxy.sh"
ok "muse_side.sh cai helper python canh proxy socat" \
  grep -q "ts-connect-proxy.py" "$REPO_DIR/bridge/muse_side.sh"
ok "bundle keo tu may ngoai co helper python" \
  grep -q "ts-connect-proxy.py" "$REPO_DIR/bridge/reverse-tunnel.sh"

echo "== 9. proxy helper chay duoc khi container THIEU socat"
# PATH gia khong co socat -> ts-socat-proxy.sh phai fallback sang python
mkdir -p "$TMP/fakebin"
for b in bash timeout cat python3 dirname mktemp; do
  p="$(command -v "$b" 2>/dev/null || true)"
  [ -n "$p" ] && ln -sf "$p" "$TMP/fakebin/$b"
done
port=12791
# Port trong de tranh dam vao server con sot cua lan chay truoc
while ss -tln 2>/dev/null | grep -q ":$port "; do port=$((port + 1)); done
( python3 - "$port" >"$TMP/server.log" 2>&1 <<'PY'
import socket, sys, threading
port = int(sys.argv[1])
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port)); srv.listen(5)
print("READY", flush=True)


def handle(c):
    try:
        data = c.recv(1024)
        c.sendall(b"ECHO:" + data)
    except OSError:
        pass
    finally:
        c.close()


while True:
    conn, _ = srv.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
PY
) &
server_pid=$!
# cho server len (poll log, khong dung sleep co dinh)
ready=0
for _ in $(seq 1 25); do
  grep -q READY "$TMP/server.log" 2>/dev/null && { ready=1; break; }
  sleep 0.2
done
ok "server echo len" test "$ready" = "1"
out="$( (printf 'hello'; sleep 1) | PATH="$TMP/fakebin" timeout 10 \
        bash "$REPO_DIR/bridge/ts-socat-proxy.sh" 127.0.0.1 "$port" 2>/dev/null )"
ok "duong fallback python tra loi dung" grep -q "ECHO:hello" <<<"$out"
kill "$server_pid" 2>/dev/null || true

echo
if [ "$fails" = "0" ]; then echo "PROMPT_TEST: PASS"; else echo "PROMPT_TEST: FAIL ($fails)"; fi
exit "$fails"
