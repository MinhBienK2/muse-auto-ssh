#!/bin/bash
# ==============================================================================
# muse_web_thread_test.sh - Chat rieng cua bridge: chi nhan dinh dung chat.
#
# Van de goc: driver web dan tin danh thuc vao nham chat khac cua nguoi dung -
# vao Main chat ("https://muse.ai/") hoac vao thread do quet tu History Chrome
# (thread nao co chu so cong thi dung, ke ca chat ca nhan cua user).
#
# Bai nay kiem tra:
#   1. Chi URL dang /thread/<uuid> moi la chat hop le (trang goc va /thread/new
#      deu khong phai).
#   2. open_muse() refuse khi khong mo duoc dung thread -> khong dan tin nham.
#   3. start_new_chat() refuse khi khong mo duoc chat moi.
#   4. Shell: is_thread_url / host_bridge_thread lay chat da luu trong card.
#
# Hermetic: chi dung thu muc tam, khong mo trinh duyet that.
# ==============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/muse-thread-test.XXXXXX)"
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

UUID_A="1d06decd-03a6-4c97-853d-94452c5fb688"
UUID_B="8c206986-154f-4b39-97e1-c02c0a5e31c5"

echo "== 1. thread_id / is_thread_url (muse_web.py)"
code=0
python3 - "$REPO_DIR" "$UUID_A" "$UUID_B" <<'PY' || code=$?
import sys

sys.path.insert(0, sys.argv[1] + "/bridge")
import muse_web  # noqa: E402

a, b = sys.argv[2], sys.argv[3]
bad = []


def check(cond, msg):
    if not cond:
        bad.append(msg)


check(muse_web.thread_id("https://muse.ai/thread/" + a) == a, "URL thread hop le -> lay UUID")
check(muse_web.thread_id("https://muse.ai/") == "", "trang goc khong phai thread")
check(muse_web.thread_id("https://muse.ai/thread/new") == "", "/thread/new chua tao -> khong phai thread")
check(muse_web.thread_id("https://muse.ai/thread/abc") == "", "khong phai UUID -> khong phai thread")
check(muse_web.thread_id("") == "", "chuoi rong -> khong phai thread")
check(muse_web.is_thread_url("https://muse.ai/thread/" + a), "is_thread_url: URL thread -> True")
check(not muse_web.is_thread_url("https://muse.ai/"), "is_thread_url: trang goc -> False")
check(not muse_web.is_thread_url("https://muse.ai/thread/new"), "is_thread_url: /thread/new -> False")
check(muse_web.thread_id("https://muse.ai/thread/" + a + "?x=1") == a, "bo qua query string")
if bad:
    print("\n".join(bad))
    sys.exit(1)
PY
if [ "$code" = "0" ]; then echo "  ok   - chi URL /thread/<uuid> moi la chat hop le"; else echo "  FAIL - chi URL /thread/<uuid> moi la chat hop le"; fails=$((fails + 1)); fi

echo "== 2. open_muse: khong dan tin vao chat sai"
code=0
python3 - "$REPO_DIR" "$UUID_A" "$UUID_B" <<'PY2' || code=$?
import sys

sys.path.insert(0, sys.argv[1] + "/bridge")
import muse_web  # noqa: E402

a, b = sys.argv[2], sys.argv[3]


class FakeTime:
    def __init__(self):
        self.t = 1000.0

    def time(self):
        return self.t

    def sleep(self, s):
        self.t += s


muse_web.time = FakeTime()


class FakeCDP:
    """CDP gia lap: giu nguyen URL hien tai (khong dieu huong duoc)."""

    def __init__(self, href):
        self.href = href

    def call(self, method, params=None, timeout=None):
        return {}

    def evaluate(self, expr):
        if "location.href" in expr:
            return self.href
        if "readyState" in expr:
            return "complete"
        if "querySelector" in expr:
            return True
        return None


bad = []

# (a) thread khong phai URL thread hop le (Main chat) -> phai raise
try:
    muse_web.open_muse(FakeCDP("https://muse.ai/"), "https://muse.ai/", "https://muse.ai/", False)
    bad.append("Main chat duoc chap nhan lam muc tieu -> se dan tin nham")
except RuntimeError:
    pass

# (b) dieu huong that bai (van o chat khac) -> phai raise
try:
    muse_web.open_muse(
        FakeCDP("https://muse.ai/thread/" + b),
        "https://muse.ai/thread/" + a,
        "https://muse.ai/thread/" + a,
        False,
    )
    bad.append("dieu huong that bai van gui -> se dan tin nham")
except RuntimeError:
    pass

# (c) start_new_chat khong mo duoc chat moi -> phai raise
try:
    muse_web.start_new_chat(FakeCDP("https://muse.ai/"))
    bad.append("start_new_chat that bai khong raise -> se dan tin nham")
except RuntimeError:
    pass

if bad:
    print("\n".join(bad))
    sys.exit(1)
PY2
if [ "$code" = "0" ]; then echo "  ok   - refuse khi khong xac dinh duoc chat dung"; else echo "  FAIL - refuse khi khong xac dinh duoc chat dung"; fails=$((fails + 1)); fi

echo "== 3. open_muse: dieu huong dung thread -> OK"
code=0
python3 - "$REPO_DIR" "$UUID_A" <<'PY3' || code=$?
import sys

sys.path.insert(0, sys.argv[1] + "/bridge")
import muse_web  # noqa: E402

a = sys.argv[2]


class FakeTime:
    def __init__(self):
        self.t = 1000.0

    def time(self):
        return self.t

    def sleep(self, s):
        self.t += s


muse_web.time = FakeTime()


class FakeCDP:
    def __init__(self, href):
        self.href = href

    def call(self, method, params=None, timeout=None):
        if method == "Page.navigate":
            self.href = params["url"]
        return {}

    def evaluate(self, expr):
        if "location.href" in expr:
            return self.href
        if "readyState" in expr:
            return "complete"
        if "querySelector" in expr:
            return True
        return None


url = "https://muse.ai/thread/" + a
cur = muse_web.open_muse(FakeCDP("https://muse.ai/"), url, url, False)
assert cur == url, cur
PY3
if [ "$code" = "0" ]; then echo "  ok   - dieu huong dung thread -> tra ve URL thread"; else echo "  FAIL - dieu huong dung thread -> tra ve URL thread"; fails=$((fails + 1)); fi

echo "== 4. wait_committed_thread: cho URL commit tu /thread/new sang /thread/<uuid>"
code=0
python3 - "$REPO_DIR" "$UUID_A" <<'PY4' || code=$?
import sys

sys.path.insert(0, sys.argv[1] + "/bridge")
import muse_web  # noqa: E402

a = sys.argv[2]


class FakeTime:
    def __init__(self):
        self.t = 1000.0

    def time(self):
        return self.t

    def sleep(self, s):
        self.t += s


muse_web.time = FakeTime()


class FakeCDP:
    """URL chuyen sang /thread/<uuid> sau 3 giay (nhu SPA that)."""

    def __init__(self):
        self.t = 1000.0
        self.href = "https://muse.ai/thread/new"

    def evaluate(self, expr):
        if "location.href" in expr:
            if self.t > 1003:
                return "https://muse.ai/thread/" + a
            return self.href
        return None


f = FakeCDP()
real_sleep = muse_web.time.sleep


def sleep(s):
    f.t += s


muse_web.time.sleep = sleep
muse_web.time.time = lambda: f.t
got = muse_web.wait_committed_thread(f, "", timeout=30)
assert got == "https://muse.ai/thread/" + a, got
PY4
if [ "$code" = "0" ]; then echo "  ok   - URL commit duoc sau khi gui"; else echo "  FAIL - URL commit duoc sau khi gui"; fails=$((fails + 1)); fi

echo "== 5. shell: is_thread_url / host_bridge_thread"
code=0
MUSE_BRIDGE_REPO_HOSTS="$TMP/hosts" bash -c '
  set -uo pipefail
  export MUSE_BRIDGE_LIB_ONLY=1
  source "'"$REPO_DIR"'/bridge/local_side.sh"
  mkdir -p "$MUSE_BRIDGE_REPO_HOSTS/muse-x"
  cat > "$MUSE_BRIDGE_REPO_HOSTS/muse-x/card.json" <<JSON
{"id": "muse-x", "thread": "https://muse.ai/thread/'"$UUID_A"'"}
JSON
  HOST=muse-x
  t="$(host_bridge_thread)"
  [ "$t" = "https://muse.ai/thread/'"$UUID_A"'" ] || { echo "host_bridge_thread sai: $t"; exit 1; }
  is_thread_url "https://muse.ai/thread/'"$UUID_A"'" || { echo "is_thread_url: URL thread bi tu choi"; exit 1; }
  is_thread_url "https://muse.ai/" && { echo "is_thread_url: Main chat bi chap nhan"; exit 1; }
  is_thread_url "" && { echo "is_thread_url: chuoi rong bi chap nhan"; exit 1; }
  # Card dang tro toi Main chat (truong hop that cua muse-pmb333) -> phai bo qua
  cat > "$MUSE_BRIDGE_REPO_HOSTS/muse-x/card.json" <<JSON
{"id": "muse-x", "thread": "https://muse.ai/"}
JSON
  t="$(host_bridge_thread)"
  [ -z "$t" ] || { echo "Main chat van duoc lay lam chat rieng: $t"; exit 1; }
' || code=$?
if [ "$code" = "0" ]; then echo "  ok   - shell lay chat rieng, bo qua Main chat"; else echo "  FAIL - shell lay chat rieng, bo qua Main chat"; fails=$((fails + 1)); fi

echo
if [ "$fails" = "0" ]; then echo "MUSE_WEB_THREAD_TEST: PASS"; else echo "MUSE_WEB_THREAD_TEST: FAIL ($fails)"; fi
exit "$fails"
