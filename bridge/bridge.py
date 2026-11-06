#!/usr/bin/env python3
"""muse-bridge :: message bus core (shared by BOTH agents).

One file, no third-party deps.  It is the single source of truth for the
protocol described in PROTOCOL.md and is embedded verbatim into MUSE_PROMPT.md
(rendered by scripts/render_prompt.py) so both agents run byte-identical code.

Spool layout (per side, path comes from config):
    <spool>/inbox/    messages addressed to ME
    <spool>/outbox/   copies of messages I sent (pending/ if delivery failed)
    <spool>/read/     messages I already handled
    <spool>/logs/     daemon logs

Transport:
    "ssh"  -> deliver by piping the JSON into `ssh <peer> 'cat > <peer spool>/inbox/<id>.json'`
    "dir"  -> deliver by writing the file directly (used by tests / same-host setups)

Usage:
    bridge.py send   --type TASK --subject "..." [--body "..." | --body-file F]
    bridge.py inbox  [--type T] [--unread] [--json] [--mark-read] [--watch]
    bridge.py ack    <ID>
    bridge.py status [--json]
    bridge.py sync                      # retry messages stuck in outbox/pending-*
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone

PROTOCOL_VERSION = 1
MSG_TYPES = ["HELLO", "TASK", "QUESTION", "ANSWER", "STATUS", "REPORT", "NOTE", "BYE"]
DEFAULT_CONFIG_PATH = os.path.join(os.path.expanduser("~"), ".muse-bridge", "config.json")
SPOOL_SUBDIRS = ("inbox", "outbox", "read", "logs", "pending")


# --------------------------------------------------------------------------- utils
def expand(path: str) -> str:
    return os.path.abspath(os.path.expanduser(os.path.expandvars(str(path))))


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def new_id() -> str:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return "%s-%s" % (stamp, uuid.uuid4().hex[:8])


def die(msg: str, code: int = 2):
    sys.stderr.write("bridge: %s\n" % msg)
    sys.exit(code)


def config_path(host: str | None = None, path: str | None = None) -> str:
    """Thu muc config: ~/.muse-bridge/hosts/<id>.json cho tung Muse host."""
    if path:
        return expand(path)
    if host:
        return expand(os.path.join(os.path.expanduser("~"), ".muse-bridge", "hosts", host + ".json"))
    env = os.environ.get("MUSE_BRIDGE_CONFIG")
    if env:
        return expand(env)
    env_host = os.environ.get("MUSE_BRIDGE_HOST")
    if env_host:
        return expand(os.path.join(os.path.expanduser("~"), ".muse-bridge", "hosts", env_host + ".json"))
    default = expand(DEFAULT_CONFIG_PATH)
    if os.path.isfile(default):
        return default
    hosts_dir = expand(os.path.join(os.path.expanduser("~"), ".muse-bridge", "hosts"))
    if os.path.isdir(hosts_dir):
        ids = sorted(n[:-5] for n in os.listdir(hosts_dir) if n.endswith(".json"))
        if len(ids) == 1:
            return os.path.join(hosts_dir, ids[0] + ".json")
        if ids:
            marker = os.path.join(os.path.expanduser("~"), ".muse-bridge", "default-host")
            if os.path.isfile(marker):
                with open(marker, "r", encoding="utf-8") as fh:
                    want = fh.read().strip()
                if want in ids:
                    return os.path.join(hosts_dir, want + ".json")
    return default


def load_config(path: str | None = None, host: str | None = None) -> dict:
    path = config_path(host, path)
    if not os.path.isfile(path):
        die("no config at %s (run: bash scripts/bridge.sh arm --host <id>)" % path)
    try:
        with open(path, "r", encoding="utf-8") as fh:
            cfg = json.load(fh)
    except Exception as exc:  # noqa: BLE001
        die("cannot parse %s: %s" % (path, exc))
    cfg["_config_path"] = path
    cfg["spool"] = expand(cfg.get("spool") or os.path.join(os.path.expanduser("~"), ".muse-bridge"))
    peer = cfg.setdefault("peer", {})
    peer.setdefault("role", "peer")
    peer.setdefault("transport", "ssh")
    peer.setdefault("host", "127.0.0.1")
    peer.setdefault("port", 22)
    peer.setdefault("user", "root")
    peer.setdefault("spool", os.path.join(expand(peer["spool"] if "spool" in peer else "~/.muse-bridge"), ""))
    peer["spool"] = expand(peer["spool"])
    peer.setdefault("ssh_opts", [])
    cfg.setdefault("id", os.path.splitext(os.path.basename(path))[0])
    return cfg


def ensure_spool(cfg: dict) -> None:
    for sub in SPOOL_SUBDIRS:
        os.makedirs(os.path.join(cfg["spool"], sub), exist_ok=True)


# --------------------------------------------------------------------------- message
def build_message(cfg: dict, args) -> dict:
    if args.type not in MSG_TYPES:
        die("unknown message type %r (known: %s)" % (args.type, ", ".join(MSG_TYPES)))
    if args.body_file:
        if args.body_file == "-":
            body = sys.stdin.read()
        else:
            try:
                with open(args.body_file, "r", encoding="utf-8") as fh:
                    body = fh.read()
            except OSError as exc:
                die("cannot read body file %s: %s" % (args.body_file, exc))
    else:
        body = args.body or ""
    meta = {}
    for item in args.meta or []:
        if "=" not in item:
            die("--meta expects KEY=VALUE, got %r" % item)
        key, value = item.split("=", 1)
        meta[key] = value
    return {
        "v": PROTOCOL_VERSION,
        "id": new_id(),
        "ts": now_iso(),
        "from": cfg.get("role", "unknown"),
        "to": args.to or cfg["peer"].get("role", "peer"),
        "host": getattr(args, "host_override", "") or cfg["peer"].get("id") or cfg.get("id"),
        "type": args.type,
        "subject": args.subject or "",
        "body": body,
        "reply_to": args.reply_to or None,
        "meta": meta,
    }


def msg_path(spool: str, folder: str, msg_id: str) -> str:
    return os.path.join(spool, folder, "%s.json" % msg_id)


def write_json(path: str, payload: dict) -> None:
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    os.replace(tmp, path)


# --------------------------------------------------------------------------- transport
def ssh_base_cmd(peer: dict) -> list:
    cmd = ["ssh"]
    opts = list(peer.get("ssh_opts") or [])
    cmd += opts
    cmd += ["-p", str(peer.get("port", 22))]
    cmd.append("%s@%s" % (peer.get("user", "root"), peer.get("host", "127.0.0.1")))
    return cmd


def remote_write_cmd(peer: dict, msg_id: str) -> str:
    inbox = os.path.join(peer["spool"], "inbox")
    quoted_inbox = "'" + inbox.replace("'", "'\\''") + "'"
    qid = "'" + msg_id.replace("'", "'\\''") + "'"
    return (
        "umask 077; mkdir -p %s && cat > %s/.tmp-%s && mv -f %s/.tmp-%s %s/%s.json"
        % (quoted_inbox, quoted_inbox, qid, quoted_inbox, qid, quoted_inbox, qid)
    )


def deliver(cfg: dict, msg: dict) -> tuple:
    """Deliver msg to the peer. Returns (state, detail)."""
    peer = cfg["peer"]
    transport = peer.get("transport", "ssh")
    if transport == "dir":
        inbox = os.path.join(peer["spool"], "inbox")
        os.makedirs(inbox, exist_ok=True)
        write_json(os.path.join(inbox, "%s.json" % msg["id"]), msg)
        return "DELIVERED", "dir:%s" % inbox

    cmd = ssh_base_cmd(peer) + [remote_write_cmd(peer, msg["id"])]
    payload = json.dumps(msg, ensure_ascii=False, indent=2) + "\n"
    try:
        proc = subprocess.run(
            cmd, input=payload, text=True, capture_output=True, timeout=peer.get("timeout", 45)
        )
    except subprocess.TimeoutExpired:
        return "QUEUED", "ssh timeout"
    except FileNotFoundError:
        return "QUEUED", "ssh binary not found"
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip().splitlines()
        return "QUEUED", (detail[-1] if detail else "ssh exit %d" % proc.returncode)
    return "DELIVERED", "ssh %s@%s" % (peer.get("user"), peer.get("host"))


def probe_peer(cfg: dict) -> tuple:
    peer = cfg["peer"]
    if peer.get("transport") == "dir":
        return "OK", "dir"
    cmd = ssh_base_cmd(peer) + ["echo BRIDGE_OK"]
    try:
        proc = subprocess.run(
            cmd,
            text=True,
            capture_output=True,
            stdin=subprocess.DEVNULL,
            timeout=peer.get("timeout", 30),
        )
    except subprocess.TimeoutExpired:
        return "DOWN", "timeout"
    except FileNotFoundError:
        return "DOWN", "no ssh"
    if proc.returncode == 0 and "BRIDGE_OK" in proc.stdout:
        return "OK", "ssh"
    detail = (proc.stderr or "").strip().splitlines()
    return "DOWN", (detail[-1] if detail else "ssh exit %d" % proc.returncode)


# --------------------------------------------------------------------------- commands
def cmd_send(cfg: dict, args) -> int:
    ensure_spool(cfg)
    msg = build_message(cfg, args)
    write_json(msg_path(cfg["spool"], "outbox", msg["id"]), msg)
    state, detail = deliver(cfg, msg)
    if state != "DELIVERED":
        shutil.move(
            msg_path(cfg["spool"], "outbox", msg["id"]),
            msg_path(cfg["spool"], "pending", msg["id"]),
        )
    print("%s id=%s type=%s to=%s (%s: %s)" % (state, msg["id"], msg["type"], msg["to"], state, detail))
    return 0 if state == "DELIVERED" else 3


def read_messages(cfg: dict, unread_only: bool = True) -> list:
    inbox = os.path.join(cfg["spool"], "inbox")
    if not os.path.isdir(inbox):
        return []
    msgs = []
    for name in sorted(os.listdir(inbox)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(inbox, name)
        try:
            with open(path, "r", encoding="utf-8") as fh:
                msgs.append(json.load(fh))
        except Exception as exc:  # noqa: BLE001
            sys.stderr.write("bridge: skip unreadable %s (%s)\n" % (path, exc))
    if unread_only:
        msgs = [m for m in msgs if not os.path.isfile(msg_path(cfg["spool"], "read", m.get("id", "")))]
    return msgs


def format_message(msg: dict) -> str:
    lines = [
        "--- %s" % msg.get("id", "?"),
        "type=%s from=%s to=%s ts=%s" % (msg.get("type"), msg.get("from"), msg.get("to"), msg.get("ts")),
    ]
    if msg.get("subject"):
        lines.append("subject=%s" % msg["subject"])
    if msg.get("reply_to"):
        lines.append("reply_to=%s" % msg["reply_to"])
    if msg.get("meta"):
        lines.append("meta=%s" % json.dumps(msg["meta"], ensure_ascii=False))
    body = msg.get("body") or ""
    if body:
        lines.append("body:")
        lines.append(body.rstrip())
    return "\n".join(lines)


def cmd_inbox(cfg: dict, args) -> int:
    ensure_spool(cfg)
    if args.watch:
        seen = set()
        while True:
            for msg in read_messages(cfg, unread_only=True):
                if msg.get("id") in seen:
                    continue
                seen.add(msg.get("id"))
                print(json.dumps(msg, ensure_ascii=False) if args.json else format_message(msg))
                sys.stdout.flush()
                if args.mark_read:
                    mark_read(cfg, msg)
            time.sleep(max(1, args.interval))
    msgs = read_messages(cfg, unread_only=not args.all)
    if args.type:
        msgs = [m for m in msgs if m.get("type") == args.type]
    if args.json:
        print(json.dumps(msgs, ensure_ascii=False, indent=2))
    else:
        if not msgs:
            print("(inbox empty)")
        for msg in msgs:
            print(format_message(msg))
            print("")
    if args.mark_read:
        for msg in msgs:
            mark_read(cfg, msg)
    return 0


def mark_read(cfg: dict, msg: dict) -> None:
    src = msg_path(cfg["spool"], "inbox", msg.get("id", ""))
    dst = msg_path(cfg["spool"], "read", msg.get("id", ""))
    if os.path.isfile(src):
        shutil.move(src, dst)


def cmd_ack(cfg: dict, args) -> int:
    ensure_spool(cfg)
    src = msg_path(cfg["spool"], "inbox", args.id)
    if not os.path.isfile(src):
        die("no message %s in inbox" % args.id)
    shutil.move(src, msg_path(cfg["spool"], "read", args.id))
    print("ACK id=%s" % args.id)
    return 0


def cmd_sync(cfg: dict, args) -> int:
    ensure_spool(cfg)
    pending_dir = os.path.join(cfg["spool"], "pending")
    names = sorted(n for n in os.listdir(pending_dir) if n.endswith(".json"))
    if not names:
        print("SYNC nothing-pending")
        return 0
    ok = 0
    for name in names:
        path = os.path.join(pending_dir, name)
        with open(path, "r", encoding="utf-8") as fh:
            msg = json.load(fh)
        state, detail = deliver(cfg, msg)
        print("%s id=%s (%s)" % (state, msg.get("id"), detail))
        if state == "DELIVERED":
            shutil.move(path, msg_path(cfg["spool"], "outbox", msg.get("id", "")))
            ok += 1
    return 0 if ok == len(names) else 3



def cmd_pull(cfg: dict, args) -> int:
    """Keo tin nhan tu peer (huong peer -> toi) qua keh SSH dang chay.

    Can cho truyen hai huong khi phia peer khong tao duoc ket noi outbound
    (container Muse bi boot lai / egress bi chan): tin cua peer nam trong
    pending/ hoac outbox/ cua no, tao keo ve inbox cua minh.
    """
    ensure_spool(cfg)
    peer = cfg["peer"]
    if peer.get("transport") == "dir":
        src_dirs = [os.path.join(peer["spool"], "pending"), os.path.join(peer["spool"], "outbox")]
        pulled = 0
        for d in src_dirs:
            if not os.path.isdir(d):
                continue
            for name in sorted(os.listdir(d)):
                if not name.endswith(".json"):
                    continue
                src = os.path.join(d, name)
                with open(src, "r", encoding="utf-8") as fh:
                    msg = json.load(fh)
                if already_seen(cfg, msg.get("id", "")):
                    os.remove(src)
                    continue
                dst = msg_path(cfg["spool"], "inbox", msg.get("id", ""))
                write_json(dst, msg)
                os.remove(src)
                pulled += 1
        print("PULL messages=%d (dir)" % pulled)
        return 0

    remote = (
        "set -e; mkdir -p %(peer)s/pulled; "
        "for f in %(peer)s/pending/*.json %(peer)s/outbox/*.json; do "
        "  [ -f \"$f\" ] || continue; n=$(basename \"$f\"); "
        "  [ -f %(peer)s/pulled/$n ] && rm -f \"$f\" && continue; "
        "  cp \"$f\" %(peer)s/pulled/$n; cat \"$f\"; "
        "  echo '<<<MUSE_BRIDGE_FILE_EOF>>>'; rm -f \"$f\"; "
        "done"
    ) % {"peer": peer["spool"]}

    cmd = ssh_base_cmd(peer) + [remote]
    try:
        proc = subprocess.run(
            cmd, text=True, capture_output=True, stdin=subprocess.DEVNULL,
            timeout=peer.get("timeout", 90)
        )
    except subprocess.TimeoutExpired:
        print("PULL timeout")
        return 3
    except FileNotFoundError:
        print("PULL no-ssh")
        return 3
    if proc.returncode != 0:
        detail = (proc.stderr or "").strip().splitlines()
        print("PULL failed: %s" % (detail[-1] if detail else "ssh exit %d" % proc.returncode))
        return 3

    pulled = 0
    for chunk in proc.stdout.split("<<<MUSE_BRIDGE_FILE_EOF>>>"):
        chunk = chunk.strip()
        if not chunk:
            continue
        try:
            msg = json.loads(chunk)
        except ValueError:
            continue
        mid = msg.get("id", "")
        if not mid or already_seen(cfg, mid):
            continue
        write_json(msg_path(cfg["spool"], "inbox", mid), msg)
        pulled += 1
    print("PULL messages=%d" % pulled)
    return 0


def already_seen(cfg: dict, msg_id: str) -> bool:
    if not msg_id:
        return False
    return os.path.isfile(msg_path(cfg["spool"], "inbox", msg_id)) or os.path.isfile(
        msg_path(cfg["spool"], "read", msg_id)
    )


def cmd_status(cfg: dict, args) -> int:
    ensure_spool(cfg)
    peer = cfg["peer"]
    peer_state, peer_detail = probe_peer(cfg)
    counts = {}
    for sub in ("inbox", "outbox", "pending", "read"):
        d = os.path.join(cfg["spool"], sub)
        counts[sub] = len([n for n in os.listdir(d) if n.endswith(".json")]) if os.path.isdir(d) else 0
    msgs = read_messages(cfg, unread_only=True)
    last = msgs[-1] if msgs else None
    info = {
        "role": cfg.get("role"),
        "id": cfg.get("id"),
        "config": cfg["_config_path"],
        "spool": cfg["spool"],
        "peer": {
            "role": peer.get("role"),
            "transport": peer.get("transport"),
            "host": peer.get("host"),
            "port": peer.get("port"),
            "user": peer.get("user"),
            "spool": peer.get("spool"),
        },
        "peer_state": peer_state,
        "peer_detail": peer_detail,
        "counts": counts,
        "last_message": {"id": last.get("id"), "type": last.get("type"), "ts": last.get("ts")} if last else None,
    }
    if args.json:
        print(json.dumps(info, ensure_ascii=False, indent=2))
        return 0 if peer_state == "OK" else 3
    print("ROLE=%s" % info["role"])
    print("HOST_ID=%s" % cfg.get("id"))
    print("CONFIG=%s" % info["config"])
    print("SPOOL=%s" % info["spool"])
    print("PEER=%s@%s:%s (%s)" % (peer.get("user"), peer.get("host"), peer.get("port"), peer.get("role")))
    print("PEER_TRANSPORT=%s" % peer.get("transport"))
    print("PEER_STATE=%s" % peer_state)
    print("PEER_DETAIL=%s" % peer_detail)
    print("INBOX=%d OUTBOX=%d PENDING=%d READ=%d" % (counts["inbox"], counts["outbox"], counts["pending"], counts["read"]))
    if last:
        print("LAST=%s %s %s" % (last.get("id"), last.get("type"), last.get("ts")))
    return 0 if peer_state == "OK" else 3


# --------------------------------------------------------------------------- cli
def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="bridge.py", description="muse-bridge message bus")
    p.add_argument("--config", help="path to config.json")
    p.add_argument("--host", help="id cua Muse host (config: ~/.muse-bridge/hosts/<id>.json)")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("send", help="send a message to the peer")
    s.add_argument("--type", required=True, choices=MSG_TYPES)
    s.add_argument("--subject", default="")
    s.add_argument("--body", default="")
    s.add_argument("--body-file", default="")
    s.add_argument("--to", default="")
    s.add_argument("--reply-to", default="")
    s.add_argument("--meta", action="append")
    s.add_argument("--host", dest="host_override", default="", help="ghi de dinh danh Muse host tren tin nhan")

    i = sub.add_parser("inbox", help="read messages addressed to me")
    i.add_argument("--type", default="")
    i.add_argument("--all", action="store_true", help="include already-read messages")
    i.add_argument("--json", action="store_true")
    i.add_argument("--mark-read", action="store_true")
    i.add_argument("--watch", action="store_true")
    i.add_argument("--interval", type=int, default=3)

    a = sub.add_parser("ack", help="acknowledge (move to read/) a message id")
    a.add_argument("id")

    sub.add_parser("sync", help="retry delivery of pending messages")
    sub.add_parser("pull", help="keo tin nhan tu peer ve inbox cua toi")
    st = sub.add_parser("status", help="show channel status")
    st.add_argument("--json", action="store_true")
    return p


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    cfg = load_config(args.config, args.host)
    if args.cmd == "send":
        return cmd_send(cfg, args)
    if args.cmd == "inbox":
        return cmd_inbox(cfg, args)
    if args.cmd == "ack":
        return cmd_ack(cfg, args)
    if args.cmd == "sync":
        return cmd_sync(cfg, args)
    if args.cmd == "pull":
        return cmd_pull(cfg, args)
    if args.cmd == "status":
        return cmd_status(cfg, args)
    return 2


if __name__ == "__main__":
    sys.exit(main())
