#!/bin/bash
# ==============================================================================
# selfheal_test.sh - Kiem tra tu phuc hoi THAT tren container Muse.
#
#   bash tests/selfheal_test.sh --host <id> [--port N]
#
# Lam gi:
#   1. xac nhan kenh dang song
#   2. GIET tien trinh tunnel tren container (simulate mat ket noi)
#   3. cho <= 90s va xem kenh co tu len lai khong (watchdog/systemd/loop)
#   4. ket luon: doi bus van chay (pull + send)
# ==============================================================================
set -uo pipefail

HOST=""
PORT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$HOST" ] || { echo "usage: selfheal_test.sh --host <id>"; exit 2; }
[ -n "$PORT" ] || PORT="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['peer']['port'])" "$HOME/.muse-bridge/hosts/$HOST.json")"

SSH=(ssh -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
     -o BatchMode=yes -o ConnectTimeout=10 root@127.0.0.1)

alive() { "${SSH[@]}" 'true' >/dev/null 2>&1; }

echo "== 1. kenh dang song?"
if alive; then echo "  ok   - port $PORT OK"; else echo "  FAIL - port $PORT khong song"; exit 1; fi

echo "== 2. giet tunnel tren container"
"${SSH[@]}" 'pkill -f "[s]sh -N -R '"$PORT"':" ; echo killed' >/dev/null 2>&1
sleep 2
alive && echo "  (van con song - container co supervisor khac)" || echo "  ok   - da ket tunnel"

echo "== 3. cho kenh tu phuc hoi (toi da 90s)"
back=0
for i in $(seq 1 18); do
  sleep 5
  if alive; then back=1; echo "  ok   - kenh da tro lai sau ~$((i*5))s"; break; fi
done
[ "$back" = "1" ] || { echo "  FAIL - kenh khong tu phuc hoi trong 90s"; exit 1; }

echo "== 4. bus van chay?"
python3 "$HOME/.muse-bridge/bridge.py" --host "$HOST" pull >/dev/null 2>&1
out="$(python3 "$HOME/.muse-bridge/bridge.py" --host "$HOST" send --type NOTE --subject "selfheal check" --body "ok" 2>&1)"
echo "$out" | grep -q "^DELIVERED"
if [ $? -eq 0 ]; then echo "  ok   - gui tin nguoc thanh cong"; else echo "  FAIL - gui tin that bai: $out"; exit 1; fi

echo "SELFTEST[$HOST]: PASS"
