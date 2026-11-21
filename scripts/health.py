#!/usr/bin/env python3
"""Theo doi suc khoe + thoi gian song cua Muse host (container).

Container Muse bi platform refresh xoa moi "/" (overlay) - chi /home/hatch
ben vung. Script nay ghi 1 dong JSON moi 5 phut vao <state>/health/<id>.jsonl
va tinh lai:
  - so lan RESTART (boot_id doi giua 2 mau lien tiep)
  - thoi gian song hien tai, boot gan nhat, uptime dai nhat
  - so lan DOWN (khong noi duoc) + tong so mau down

Usage:
  python3 scripts/health.py sample --host <id> --port <p> --state-dir <dir>
                                    [--config <host.json>] [--peer <peer.json>]
  python3 scripts/health.py show   --state-dir <dir> [--host <id>] [--json]
"""

from __future__ import annotations

import datetime
import json
import os
import sys
import time

MAX_LINES = 50000


def now_iso() -> str:
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def parse_ts(ts: str) -> datetime.datetime | None:
    try:
        return datetime.datetime.fromisoformat(ts)
    except (TypeError, ValueError):
        return None


def load_json(path: str) -> dict:
    """Doc JSON; tra {} neu file khong ton tai / hong."""
    if not path or not os.path.exists(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def count_spool(spool: str, folder: str) -> int:
    d = os.path.join(spool, folder)
    if not os.path.isdir(d):
        return 0
    return len([f for f in os.listdir(d) if f.endswith(".json")])


def local_spool_counts(config_path: str) -> dict:
    cfg = load_json(config_path)
    spool = cfg.get("spool", "") or ""
    if not spool:
        return {}
    return {f"local_{f}": count_spool(spool, f) for f in ("inbox", "outbox", "pending", "read")}


def cmd_sample(args: list[str]) -> int:
    host = _opt(args, "--host")
    port = _opt(args, "--port")
    state_dir = _opt(args, "--state-dir")
    config = _opt(args, "--config")
    peer_file = _opt(args, "--peer")
    if not host or not state_dir:
        print(__doc__, file=sys.stderr)
        return 2

    peer = load_json(peer_file) if peer_file else {}
    reachable = bool(peer)

    # Thoi gian song THAT = gio kernel boot (btime) -> hien tai. Khong dung
    # /proc/uptime: container bi nen tang suspend/resume lam no nhay nguoc.
    boot_epoch = int(peer.get("boot_epoch") or 0)
    if boot_epoch:
        uptime_s = max(0, int(time.time()) - boot_epoch)
    else:
        uptime_s = int(peer.get("uptime_s") or 0)

    row = {
        "ts": now_iso(),
        "host": host,
        "port": int(port) if port.isdigit() else 0,
        "reachable": reachable,
        "boot_id": peer.get("boot_id", ""),
        "boot_epoch": boot_epoch,
        "uptime_s": uptime_s,
        "mem_available_mb": peer.get("mem_available_mb", 0),
        "disk_free_mb": peer.get("disk_free_mb", 0),
        "durable": peer.get("durable", ""),
        "peer_inbox": peer.get("peer_inbox", 0),
        "peer_outbox": peer.get("peer_outbox", 0),
        "peer_pending": peer.get("peer_pending", 0),
        "peer_read": peer.get("peer_read", 0),
        "sshd": peer.get("sshd", ""),
        "tunnel": peer.get("tunnel", 0),
    }
    row.update(local_spool_counts(config))

    os.makedirs(os.path.join(state_dir, host), exist_ok=True)
    path = os.path.join(state_dir, host, "samples.jsonl")
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(row, ensure_ascii=False) + "\n")
    _prune(path)
    print(json.dumps(row, ensure_ascii=False))
    return 0


def _prune(path: str) -> None:
    """Giu file mau kich thuoc vua phai (moi 5 phut -> ~105k dong/nam)."""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            lines = fh.readlines()
    except OSError:
        return
    if len(lines) <= MAX_LINES:
        return
    keep = lines[-MAX_LINES // 2 :]
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.writelines(keep)
    os.replace(tmp, path)


def load_samples(state_dir: str, host: str) -> list[dict]:
    path = os.path.join(state_dir, host, "samples.jsonl")
    if not os.path.exists(path):
        return []
    out = []
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except ValueError:
                continue
    return out


def fmt_uptime(seconds: float) -> str:
    s = int(seconds or 0)
    if s <= 0:
        return "-"
    d, rem = divmod(s, 86400)
    h, m = divmod(rem, 3600)
    m //= 60
    if d:
        return f"{d}d{h}h"
    if h:
        return f"{h}h{m}m"
    return f"{m}m"


def stats(samples: list[dict]) -> dict:
    """Restart = boot_id doi giua 2 mau lien tiep (ca 2 deu reachable).

    Doi boot_id = container bi thay instance (platform refresh). Moi instance
    duoc do bang thoi gian tu lan thay den lan thay tiep theo.
    """
    restarts = 0
    outages = 0
    down_samples = 0
    last_restart_ts = ""
    prev_boot = ""
    prev_up = True
    uptimes = []
    lifetimes = []
    first_seen = {}
    boot_changed = False

    for s in samples:
        up = bool(s.get("reachable"))
        boot = s.get("boot_id", "") or ""
        if up:
            uptimes.append(int(s.get("uptime_s") or 0))
            if prev_boot and boot and boot != prev_boot:
                restarts += 1
                last_restart_ts = s.get("ts", "")
                boot_changed = True
                # thoi gian song cua instance vua bi thay
                born = first_seen.get(prev_boot)
                now_ts = parse_ts(s.get("ts", ""))
                if born and now_ts:
                    lifetimes.append(int((now_ts - born).total_seconds()))
                first_seen[boot] = now_ts
            elif not prev_boot and boot:
                first_seen[boot] = parse_ts(s.get("ts", ""))
            prev_boot = boot or prev_boot
        else:
            down_samples += 1
            if prev_up:
                outages += 1
        prev_up = up

    last = samples[-1] if samples else {}
    first = samples[0] if samples else {}
    uptime_now = int(last.get("uptime_s") or 0) if last.get("reachable") else 0
    boot_at = ""
    if uptime_now and last.get("ts"):
        ts = parse_ts(last["ts"])
        if ts:
            boot_at = (ts - datetime.timedelta(seconds=uptime_now)).isoformat(timespec="seconds")

    return {
        "samples": len(samples),
        "first_ts": first.get("ts", ""),
        "last_ts": last.get("ts", ""),
        "reachable": bool(last.get("reachable")) if last else False,
        "boot_id": last.get("boot_id", ""),
        "uptime_s": uptime_now,
        "uptime_human": fmt_uptime(uptime_now),
        "boot_at": boot_at,
        "restarts": restarts,
        "last_restart_ts": last_restart_ts,
        "outages": outages,
        "down_samples": down_samples,
        "max_uptime_s": max(uptimes) if uptimes else 0,
        "max_uptime_human": fmt_uptime(max(uptimes) if uptimes else 0),
        "avg_uptime_s": int(sum(uptimes) / len(uptimes)) if uptimes else 0,
        "avg_instance_lifetime_s": int(sum(lifetimes) / len(lifetimes)) if lifetimes else 0,
        "avg_instance_lifetime_human": fmt_uptime(
            int(sum(lifetimes) / len(lifetimes)) if lifetimes else 0
        ),
        "mem_available_mb": last.get("mem_available_mb", 0),
        "disk_free_mb": last.get("disk_free_mb", 0),
        "durable": last.get("durable", ""),
        "peer_inbox": last.get("peer_inbox", 0),
        "peer_outbox": last.get("peer_outbox", 0),
        "peer_pending": last.get("peer_pending", 0),
        "peer_read": last.get("peer_read", 0),
        "local_inbox": last.get("local_inbox", 0),
        "local_outbox": last.get("local_outbox", 0),
        "sshd": last.get("sshd", ""),
        "tunnel": last.get("tunnel", 0),
        "boot_changed_last": boot_changed,
    }


def cmd_show(args: list[str]) -> int:
    state_dir = _opt(args, "--state-dir")
    host = _opt(args, "--host")
    as_json = "--json" in args
    if not state_dir:
        print(__doc__, file=sys.stderr)
        return 2
    if host:
        hosts = [host]
    else:
        hosts = sorted(
            d for d in os.listdir(state_dir) if os.path.isdir(os.path.join(state_dir, d))
        )

    all_stats = {}
    for h in hosts:
        all_stats[h] = stats(load_samples(state_dir, h))

    if as_json:
        print(json.dumps(all_stats, ensure_ascii=False, indent=2))
        return 0

    print(f"{'HOST':<14} {'STATE':<6} {'UPTIME':<8} {'RESTART':<8} {'LAST-RESTART':<20} {'AVG-LIFE':<10} {'MEM-MB':<7} {'PEER-IN':<9} {'LOCAL-IN'}")
    for h, s in all_stats.items():
        state = "UP" if s["reachable"] else "DOWN"
        last_restart = s["last_restart_ts"].replace("T", " ")[:19] if s["last_restart_ts"] else "-"
        print(
            f"{h:<14} {state:<6} {s['uptime_human']:<8} {s['restarts']:<8} {last_restart:<20} "
            f"{s['avg_instance_lifetime_human']:<10} {s['mem_available_mb']:<7} {s['peer_inbox']:<9} {s['local_inbox']}"
        )
    print()
    for h, s in all_stats.items():
        durable = s["durable"] or "(khong co thu ben vung)"
        print(
            f"[{h}] mau={s['samples']} down={s['outages']} lan ({s['down_samples']} mau) "
            f"boot_luc={s['boot_at'] or '-'} durable={durable} "
            f"sshd={s['sshd'] or '?'} tunnel={s['tunnel']}"
        )
    return 0


def _opt(args: list[str], name: str) -> str:
    if name in args:
        i = args.index(name)
        if i + 1 < len(args):
            return args[i + 1]
    return ""


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, rest = args[0], args[1:]
    if cmd == "sample":
        return cmd_sample(rest)
    if cmd == "show":
        return cmd_show(rest)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
