#!/usr/bin/env python3
"""muse_web.py - dieu khien trinh duyet cua nguoi dung de gui prompt vao web Muse.

Khong can thu vien ngoai: WebSocket client + CDP duoc viet bang Python chuan.

Tinh huong dung:
  1. Chrome cua nguoi dung da dang nhap muse.ai.
  2. Script clone profile (giu cookie/session) va mo mot Chrome rieng voi
     --remote-debugging-port => khong cham vao Chrome dang chay cua nguoi dung.
  3. Script mo muse.ai, dan prompt vao o chat, bam Enter, cho reply va tra ve.

Lenh:
  python3 muse_web.py ensure  [--cdp-port 9222] [--profile-src DIR] [--clone-dir DIR]
  python3 muse_web.py send    --file PROMPT [--url URL] [--cdp-port 9222]
                               [--wait-for REGEX] [--timeout 300] [--reply-out FILE]
                               [--thread URL] [--new-chat]
  python3 muse_web.py reply   [--cdp-port 9222] [--out FILE]
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import time
import urllib.request

DEFAULT_URL = "https://muse.ai/"
DEFAULT_CDP_PORT = 9222
DEFAULT_CLONE_DIR = "/tmp/muse-chrome-profile"
COMPOSER = "textarea[aria-label=\"Message\"]"


# --------------------------------------------------------------------- websocket
class WS:
    def __init__(self, url: str, timeout: float = 30):
        if not url.startswith("ws://"):
            raise ValueError("chi ho tro ws:// trong script nay: %s" % url)
        rest = url[5:]
        hostport, _, path = rest.partition("/")
        path = "/" + path
        host, _, port = hostport.partition(":")
        self.sock = socket.create_connection((host, int(port or 80)), timeout=timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        req = (
            "GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % (path, hostport, key)
        )
        self.sock.sendall(req.encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise IOError("ket noi dong khi bat tay WebSocket")
            buf += chunk
        head, _, rest_buf = buf.partition(b"\r\n\r\n")
        if b" 101 " not in head.split(b"\r\n")[0]:
            raise IOError("bat tay WebSocket that bai: %s" % head[:200])
        self.buf = rest_buf

    def _read(self, n: int) -> bytes:
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise IOError("ket noi bi dong")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def send_text(self, text: str) -> None:
        payload = text.encode()
        header = bytearray([0x81])
        mask = os.urandom(4)
        n = len(payload)
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126)
            header += struct.pack(">H", n)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", n)
        header += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(bytes(header) + masked)

    def recv_text(self) -> str:
        while True:
            b1, b2 = self._read(2)
            opcode = b1 & 0x0F
            length = b2 & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._read(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._read(8))[0]
            data = self._read(length) if length else b""
            if opcode == 0x8:
                raise IOError("server dong websocket")
            if opcode == 0x9:
                continue
            if opcode in (0x1, 0x2, 0x0):
                return data.decode("utf-8", "replace")

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass


class CDP:
    def __init__(self, ws_url: str, timeout: float = 60):
        self.ws = WS(ws_url)
        self.timeout = timeout
        self._id = 0

    def call(self, method: str, params: dict | None = None, timeout: float | None = None) -> dict:
        self._id += 1
        my_id = self._id
        self.ws.send_text(json.dumps({"id": my_id, "method": method, "params": params or {}}))
        deadline = time.time() + (timeout or self.timeout)
        while time.time() < deadline:
            raw = self.ws.recv_text()
            try:
                data = json.loads(raw)
            except ValueError:
                continue
            if data.get("id") == my_id:
                if "error" in data:
                    raise RuntimeError("%s: %s" % (method, data["error"]))
                return data.get("result", {})
        raise TimeoutError("CDP timeout: %s" % method)

    def evaluate(self, expression: str, timeout: float = 60):
        res = self.call(
            "Runtime.evaluate",
            {
                "expression": expression,
                "returnByValue": True,
                "awaitPromise": True,
                "userGesture": True,
            },
            timeout=timeout,
        )
        if res.get("exceptionDetails"):
            raise RuntimeError("JS loi: %s" % json.dumps(res["exceptionDetails"])[:400])
        return res.get("result", {}).get("value")

    def close(self) -> None:
        self.ws.close()


# --------------------------------------------------------------------- helpers
def http_json(url: str, timeout: float = 5):
    with urllib.request.urlopen(url, timeout=timeout) as fh:
        return json.loads(fh.read().decode())


def cdp_alive(port: int) -> bool:
    try:
        http_json("http://127.0.0.1:%d/json/version" % port, timeout=3)
        return True
    except Exception:  # noqa: BLE001
        return False


def attach_page(port: int, thread_url: str | None = None) -> dict:
    """Chon tab phu hop: uu tien tab dang mo dung thread, neu khong thi dieu huong vao."""
    if thread_url:
        key = thread_url.rstrip("/").split("/")[-1]
        for t in http_json("http://127.0.0.1:%d/json/list" % port, timeout=5):
            if t.get("type") == "page" and t.get("webSocketDebuggerUrl") and key in (t.get("url") or ""):
                return t
    return find_page(port, thread_url)


def find_page(port: int, prefer_url: str | None = None) -> dict:
    tabs = http_json("http://127.0.0.1:%d/json/list" % port, timeout=5)
    pages = [t for t in tabs if t.get("type") == "page" and t.get("webSocketDebuggerUrl")]
    if prefer_url:
        for t in pages:
            if prefer_url.split("#")[0] in (t.get("url") or ""):
                return t
    for t in pages:
        if "muse.ai" in (t.get("url") or ""):
            return t
    if pages:
        return pages[0]
    raise RuntimeError("khong tim thay tab nao de dieu khien")


def chrome_binary() -> str:
    for cand in (
        "/opt/google/chrome/chrome",
        "/usr/bin/google-chrome",
        "/usr/bin/chromium",
        "/usr/bin/chromium-browser",
        shutil.which("google-chrome") or "",
    ):
        if cand and os.path.exists(cand):
            return cand
    raise RuntimeError("khong tim thay Chrome")


def clone_profile(src: str, dst: str) -> None:
    """Copy cookie/session sang profile moi (de mo Chrome rieng, khong chan user)."""
    if os.path.isdir(dst):
        return
    os.makedirs(dst, exist_ok=True)
    os.makedirs(os.path.join(dst, "Default"), exist_ok=True)
    ls = os.path.join(src, "Local State")
    if os.path.isfile(ls):
        shutil.copy2(ls, os.path.join(dst, "Local State"))
    for name in (
        "Cookies",
        "Preferences",
        "Login Data",
        "Web Data",
        "Network",
        "Local Storage",
        "Session Storage",
        "IndexedDB",
    ):
        s = os.path.join(src, "Default", name)
        if os.path.exists(s):
            try:
                shutil.copytree(s, os.path.join(dst, "Default", name), dirs_exist_ok=True)
            except (OSError, shutil.Error):
                pass


def ensure_chrome(port: int, profile_src: str, clone_dir: str, headed: bool = False) -> str:
    if cdp_alive(port):
        return "http://127.0.0.1:%d" % port
    clone_profile(profile_src, clone_dir)
    args = [
        chrome_binary(),
        "--remote-debugging-port=%d" % port,
        "--user-data-dir=%s" % clone_dir,
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-background-networking",
        "--window-size=1400,900",
    ]
    if not headed:
        args.append("--headless=new")
    args.append("about:blank")
    subprocess.Popen(
        args,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    for _ in range(40):
        time.sleep(0.5)
        if cdp_alive(port):
            return "http://127.0.0.1:%d" % port
    raise RuntimeError("khong mo duoc Chrome voi CDP port %d" % port)


def open_muse(cdp: CDP, url: str, thread: str | None, new_chat: bool) -> str:
    cdp.call("Page.enable")
    cdp.call("Runtime.enable")
    if thread:
        cdp.call("Page.navigate", {"url": thread})
    elif new_chat:
        base = url.rstrip("/")
        if base.endswith("/thread/new"):
            new_url = base
        elif "/thread/" in base:
            new_url = base.rsplit("/thread/", 1)[0] + "/thread/new"
        else:
            new_url = base + "/thread/new"
        cdp.call("Page.navigate", {"url": new_url})
    else:
        cdp.call("Page.navigate", {"url": url})
    # doi cho trang load xong
    for _ in range(60):
        time.sleep(0.5)
        state = cdp.evaluate("document.readyState")
        if state in ("interactive", "complete"):
            break
    time.sleep(2)
    return cdp.evaluate("location.href") or url


def fill_composer(cdp: CDP, text: str) -> None:
    """Dung Input.insertText: app React nhan dung state (setter + input event bi bo qua)."""
    found = cdp.evaluate(
        "(() => { const ta = document.querySelector(%s); if (!ta) return 'NO_COMPOSER';"
        " ta.focus(); return 'OK'; })()" % json.dumps(COMPOSER)
    )
    if found != "OK":
        raise RuntimeError("khong tim thay o chat tren trang: %s" % found)
    cdp.call("Input.insertText", {"text": text}, timeout=120)
    length = cdp.evaluate(
        "(() => { const ta = document.querySelector(%s); return ta ? ta.value.length : -1; })()"
        % json.dumps(COMPOSER)
    )
    if length < len(text) * 0.9:
        raise RuntimeError("chi dan duoc %d/%d ky tu vao o chat" % (length, len(text)))


def assistant_messages(cdp: CDP) -> list:
    return cdp.evaluate(
        "(() => [...document.querySelectorAll('span.sr-only.whitespace-pre')]"
        ".map(e => e.textContent.trim()).filter(t => t.startsWith('Assistant message:')))()"
    ) or []


def wait_for_send_button(cdp: CDP, timeout: float = 20) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if cdp.evaluate(
            "(() => !!document.querySelector('button[aria-label=\"Send\"]'))()"
        ):
            return True
        time.sleep(0.5)
    return False


def press_enter(cdp: CDP) -> None:
    base = {
        "key": "Enter",
        "code": "Enter",
        "windowsVirtualKeyCode": 13,
        "nativeVirtualKeyCode": 13,
    }
    cdp.call("Input.dispatchKeyEvent", dict(base, type="rawKeyDown"))
    cdp.call("Input.dispatchKeyEvent", dict(base, type="char", text="\r"))
    cdp.call("Input.dispatchKeyEvent", dict(base, type="keyUp"))


def click_send_button(cdp: CDP) -> bool:
    return bool(
        cdp.evaluate(
            "(() => { const b = document.querySelector('button[aria-label=\"Send\"]');"
            " if (!b) return false; b.click(); return true; })()"
        )
    )


def click_send(cdp: CDP) -> bool:
    js = """
    (() => {
      const ta = document.querySelector(%s);
      if (!ta) return false;
      let scope = ta.parentElement;
      for (let i = 0; i < 6 && scope; i++) {
        const btns = [...scope.querySelectorAll('button')];
        for (const b of btns) {
          const label = (b.getAttribute('aria-label') || '') + ' ' + (b.getAttribute('data-testid') || '');
          if (/send|submit|arrow-up/i.test(label)) { b.click(); return true; }
        }
        scope = scope.parentElement;
      }
      return false;
    })()
    """ % json.dumps(COMPOSER)
    return bool(cdp.evaluate(js))


APPROVAL_BUTTONS = ("Allow once", "Always allow this site", "Allow", "Approve", "Deny")


def pending_approval(cdp: CDP):
    """Tra ve (loai, mo ta) cua approval dang treo trong UI (neu co)."""
    return cdp.evaluate(
        "(() => {"
        " const btns=[...document.querySelectorAll('button')]"
        "   .filter(b => /^(Allow once|Allow for this task|Always allow this site|Allow|Approve|Deny)$/i.test((b.innerText||'').trim()));"
        " if (!btns.length) return null;"
        " const scope = btns[0].closest('[role=\"dialog\"], [role=\"alertdialog\"], [data-testid*=approval]') || document.body;"
        " return (scope.innerText||'').slice(0,400);"
        "})()"
    )


def approve(cdp: CDP, mode: str = "once", rounds: int = 6) -> int:
    """Bam nut allow cho cac approval treo (modes: once | always | deny)."""
    labels = {
        "once": ["Allow once", "Allow for this task", "Allow"],
        "always": ["Always allow this site", "Allow for this task", "Allow once", "Allow"],
        "deny": ["Deny"],
    }.get(mode, ["Allow once", "Allow for this task", "Allow"])
    done = 0
    for _ in range(rounds):
        hit = cdp.evaluate(
            "(() => { const labels=%s;"
            " const btns=[...document.querySelectorAll('button')];"
            " for (const l of labels) { const b=btns"
            "   .find(x => (x.innerText||'').trim().toLowerCase() === l.toLowerCase());"
            "   if (b) { b.click(); return l; } }"
            " return null; })()" % json.dumps(labels)
        )
        if not hit:
            break
        done += 1
        time.sleep(2.5)
    return done


def page_text(cdp: CDP) -> str:
    return cdp.evaluate("document.body.innerText") or ""


def conversation_text(cdp: CDP, last: int = 6) -> str:
    """Chi phan hoi thoai (khong lay ca trang) - tranh khop nham voi chinh noi dung da dan."""
    js = (
        "(() => { const b=[...document.querySelectorAll('div.hatch-chat-groupable-bubble')]"
        ".map(e => (e.innerText||'').trim());"
        " return b.slice(-" + str(last) + ").join(String.fromCharCode(10, 10)); })()"
    )
    return cdp.evaluate(js) or ""


def assistant_text(cdp: CDP, last: int = 4) -> str:
    """Chi phan trả lời của agent (span sr-only 'Assistant message:')."""
    js = (
        "(() => { const a=[...document.querySelectorAll('span.sr-only.whitespace-pre')]"
        ".map(e => (e.textContent||'').trim())"
        ".filter(t => t.startsWith('Assistant message:'));"
        " return a.slice(-" + str(last) + ").join(String.fromCharCode(10, 10)); })()"
    )
    return cdp.evaluate(js) or ""


def wait_for(cdp: CDP, pattern: str, timeout: float) -> str:
    """Cho den khi regex khop voi phan hoi thoai moi (bo qua noi dung do nguoi dan)."""
    rx = re.compile(pattern)
    deadline = time.time() + timeout
    last = ""
    while time.time() < deadline:
        last = assistant_text(cdp) or conversation_text(cdp)
        if rx.search(last):
            return last
        time.sleep(3)
    return last


# --------------------------------------------------------------------- commands
def cmd_ensure(args) -> int:
    url = ensure_chrome(args.cdp_port, args.profile_src, args.clone_dir, headed=args.headed)
    print("CDP=%s" % url)
    print("PROFILE_CLONE=%s" % args.clone_dir)
    return 0


def cmd_send(args) -> int:
    ensure_chrome(args.cdp_port, args.profile_src, args.clone_dir, headed=args.headed)
    page = find_page(args.cdp_port)
    cdp = CDP(page["webSocketDebuggerUrl"])
    try:
        target = args.thread or args.url
        current = open_muse(cdp, target, args.thread, args.new_chat)
        print("URL=%s" % current)
        before = assistant_messages(cdp)
        if args.new_chat:
            time.sleep(2)
        with open(args.file, "r", encoding="utf-8") as fh:
            prompt = fh.read()
        fill_composer(cdp, prompt)
        time.sleep(1)
        if args.dry_run:
            print("DRY_RUN: da dan %d ky tu vao o chat (khong gui)" % len(prompt))
            return 0
        sent = False
        if wait_for_send_button(cdp, 20):
            sent = click_send_button(cdp)
        if not sent:
            press_enter(cdp)
            time.sleep(2)
        print("SENT=%s" % sent)
        print("THREAD_URL=%s" % (cdp.evaluate("location.href") or ""))
        # cho den khi co tin nhan tra loi moi cua agent
        deadline = time.time() + args.timeout
        replies = []
        while time.time() < deadline:
            approve(cdp, args.approve_mode, 4)
            replies = assistant_messages(cdp)
            if len(replies) > len(before):
                newest = replies[-1]
                if not args.wait_for or re.search(args.wait_for, newest):
                    break
            time.sleep(4)
        text = "\n\n".join(replies[-3:]) if replies else conversation_text(cdp)
        if args.reply_out:
            with open(args.reply_out, "w", encoding="utf-8") as fh:
                fh.write(text)
        print("----- REPLY -----")
        print(text[-8000:])
        print("----- END -----")
        return 0
    finally:
        cdp.close()


def cmd_say(args) -> int:
    """Gui mot tin nhan ngan vao thread hien tai (dung cho vong lap doi thoai)."""
    ensure_chrome(args.cdp_port, args.profile_src, args.clone_dir, headed=args.headed)
    page = attach_page(args.cdp_port, args.thread)
    cdp = CDP(page["webSocketDebuggerUrl"])
    try:
        if args.thread:
            cdp.call("Page.enable")
            cdp.call("Page.navigate", {"url": args.thread})
            for _ in range(40):
                time.sleep(0.5)
                if cdp.evaluate("document.readyState") in ("interactive", "complete"):
                    break
            time.sleep(2)
        with open(args.file, "r", encoding="utf-8") as fh:
            text = fh.read()
        fill_composer(cdp, text)
        time.sleep(1)
        if wait_for_send_button(cdp, 15):
            click_send_button(cdp)
        else:
            press_enter(cdp)
        print("SENT=True")
        print("THREAD_URL=%s" % (cdp.evaluate("location.href") or ""))
        if args.wait_for:
            deadline = time.time() + args.timeout
            while time.time() < deadline:
                approve(cdp, args.approve_mode, 3)
                if re.search(args.wait_for, assistant_text(cdp) or conversation_text(cdp)):
                    break
                time.sleep(3)
        print(conversation_text(cdp)[-4000:])
        return 0
    finally:
        cdp.close()


def cmd_reply(args) -> int:
    ensure_chrome(args.cdp_port, args.profile_src, args.clone_dir, headed=args.headed)
    page = attach_page(args.cdp_port, args.thread)
    cdp = CDP(page["webSocketDebuggerUrl"])
    try:
        if args.thread:
            cdp.call("Page.enable")
            cdp.call("Page.navigate", {"url": args.thread})
            for _ in range(40):
                time.sleep(0.5)
                if cdp.evaluate("document.readyState") in ("interactive", "complete"):
                    break
            time.sleep(2)
        if args.wait_for:
            deadline = time.time() + args.timeout
            text = ""
            while time.time() < deadline:
                approve(cdp, args.approve_mode, 3)
                text = assistant_text(cdp) or conversation_text(cdp)
                if re.search(args.wait_for, text):
                    break
                time.sleep(3)
        else:
            approve(cdp, args.approve_mode, 3)
            text = page_text(cdp)
        if args.out:
            with open(args.out, "w", encoding="utf-8") as fh:
                fh.write(text)
        print(text[-8000:])
        return 0
    finally:
        cdp.close()


def main() -> int:
    ap = argparse.ArgumentParser(description="muse-bridge: dieu khien web Muse qua CDP")
    ap.add_argument("--cdp-port", type=int, default=DEFAULT_CDP_PORT)
    ap.add_argument("--profile-src", default=os.path.expanduser("~/.config/google-chrome"))
    ap.add_argument("--clone-dir", default=DEFAULT_CLONE_DIR)
    ap.add_argument("--headed", action="store_true", help="hien thi cua so Chrome (mac dinh: headless)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("ensure")

    s = sub.add_parser("send")
    s.add_argument("--file", required=True)
    s.add_argument("--url", default=DEFAULT_URL)
    s.add_argument("--thread", default="")
    s.add_argument("--new-chat", action="store_true")
    s.add_argument("--wait-for", default="")
    s.add_argument("--timeout", type=float, default=300)
    s.add_argument("--reply-out", default="")
    s.add_argument("--dry-run", action="store_true", help="chi dan vao o chat, khong gui")
    s.add_argument("--approve-mode", default="once", choices=["once", "always", "deny"])

    say = sub.add_parser("say")
    say.add_argument("--file", required=True)
    say.add_argument("--thread", default="")
    say.add_argument("--wait-for", default="")
    say.add_argument("--timeout", type=float, default=120)
    say.add_argument("--approve-mode", default="once", choices=["once", "always", "deny"])

    approve_p = sub.add_parser("approve")
    approve_p.add_argument("--mode", default="once", choices=["once", "always", "deny"])
    approve_p.add_argument("--rounds", type=int, default=6)

    r = sub.add_parser("reply")
    r.add_argument("--wait-for", default="")
    r.add_argument("--timeout", type=float, default=120)
    r.add_argument("--out", default="")
    r.add_argument("--approve-mode", default="once", choices=["once", "always", "deny"])
    r.add_argument("--thread", default="", help="mo thread cu the truoc khi doc")

    args = ap.parse_args()
    try:
        if args.cmd == "ensure":
            return cmd_ensure(args)
        if args.cmd == "send":
            return cmd_send(args)
        if args.cmd == "say":
            return cmd_say(args)
        if args.cmd == "approve":
            ensure_chrome(args.cdp_port, args.profile_src, args.clone_dir, headed=args.headed)
            page = find_page(args.cdp_port)
            cdp = CDP(page["webSocketDebuggerUrl"])
            try:
                print("APPROVED=%d" % approve(cdp, args.mode, args.rounds))
                return 0
            finally:
                cdp.close()
        if args.cmd == "reply":
            return cmd_reply(args)
    except Exception as exc:  # noqa: BLE001
        print("muse_web: %s" % exc, file=sys.stderr)
        return 1
    return 2


if __name__ == "__main__":
    sys.exit(main())
