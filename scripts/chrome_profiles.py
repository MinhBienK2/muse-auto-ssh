#!/usr/bin/env python3
"""Liet ke Chrome profile tren may + profile nao con dang nhap muse.ai.

Agent (skill /setup-ssh-muse) dung script nay de hoi user chon profile:
khong hard-code "Default"/"Profile 2" trong SKILL.md - moi may mot danh sach
profile khac nhau, va mot may co the co nhieu account Muse da dang nhap.

CHI DOC, khong sua Chrome:
  <src>/Local State            -> profile.info_cache  (ten hien thi + email Google)
  <src>/<dir>/Preferences      -> account_info        (danh sach account trong profile)
  <src>/<dir>/Cookies          -> cookie muse.ai con song  (phien dang nhap)
  <src>/<dir>/History          -> so URL muse.ai          (da tung dung account do)
  <hosts-dir>/*.json           -> host nao dang dung profile do

Usage:
  python3 scripts/chrome_profiles.py [--profile-src DIR] [--hosts-dir DIR]
                                     [--json] [--text] [--only-muse]

Output mac dinh: JSON array (de agent parse). --text de in bang de doc cho nguoi.
"""

import argparse
import json
import os
import shutil
import sqlite3
import sys
import tempfile
import time

DEFAULT_SRC = os.path.expanduser("~/.config/google-chrome")
# Chrome luoi cookie theo micro-giay ke tu 1601-01-01 (Windows epoch).
CHROME_EPOCH_OFFSET = 11644473600


def _sqlite_count(db_path, sql, params=()):
    """Dem dong theo sql. Thu doc truc tiep truoc, fail thi copy ra tam roi doc.

    Chrome dang mo -> file bi khoa -> sqlite 'mode=ro' fail. Copy ra thu muc tam
    (kem -wal/-shm) la doc duoc ma khong can dung den Chrome.
    """
    if not os.path.exists(db_path):
        return None
    try:
        con = sqlite3.connect("file:%s?mode=ro" % db_path, uri=True, timeout=2)
        row = con.execute(sql, params).fetchone()
        con.close()
        return int(row[0]) if row else 0
    except sqlite3.Error:
        pass
    try:
        with tempfile.TemporaryDirectory() as tmp:
            base = os.path.basename(db_path)
            dst = os.path.join(tmp, base)
            shutil.copy2(db_path, dst)
            for suffix in ("-wal", "-shm"):
                extra = db_path + suffix
                if os.path.exists(extra):
                    shutil.copy2(extra, os.path.join(tmp, base + suffix))
            con = sqlite3.connect("file:%s?mode=ro" % dst, uri=True, timeout=2)
            row = con.execute(sql, params).fetchone()
            con.close()
            return int(row[0]) if row else 0
    except (OSError, sqlite3.Error):
        return None


def _load_json(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def _info_cache(src):
    """Local State -> {ten thu muc profile: {name, user_name(email)}}."""
    data = _load_json(os.path.join(src, "Local State"))
    cache = data.get("profile", {}).get("info_cache", {})
    out = {}
    for key, val in cache.items():
        out[key] = val if isinstance(val, dict) else {}
    return out


def _account_emails(profile_dir):
    """Preferences -> account_info -> danh sach email trong profile do."""
    prefs = _load_json(os.path.join(profile_dir, "Preferences"))
    acc = prefs.get("account_info")
    mails = []
    if isinstance(acc, list):
        mails = [a.get("email") for a in acc if isinstance(a, dict)]
    elif isinstance(acc, dict):
        mails = [acc.get("email")]
    return [m for m in mails if m]


def _profile_dirs(src, cache):
    """Ten cac thu muc profile (gop Local State + thu muc co Cookies/History)."""
    names = set(cache.keys())
    try:
        for entry in os.scandir(src):
            if not entry.is_dir() or entry.name.startswith("."):
                continue
            d = os.path.join(src, entry.name)
            if any(os.path.exists(os.path.join(d, f)) for f in ("Cookies", "History")):
                names.add(entry.name)
    except OSError:
        pass
    return sorted(names)


def _hosts_using(hosts_dir):
    """{ten profile: [host id]} tu card host trong .muse-hosts/."""
    out = {}
    if not hosts_dir or not os.path.isdir(hosts_dir):
        return out
    try:
        entries = sorted(os.listdir(hosts_dir))
    except OSError:
        return out
    for name in entries:
        if not name.endswith(".json"):
            continue
        card = _load_json(os.path.join(hosts_dir, name))
        if not isinstance(card, dict) or not card.get("id"):
            continue
        # Host chua khai bao profile -> mac dinh "Default".
        profile = card.get("web_profile_dir") or "Default"
        out.setdefault(profile, []).append(card["id"])
    return out


def scan(src, hosts_dir):
    now = (time.time() + CHROME_EPOCH_OFFSET) * 1_000_000
    cache = _info_cache(src)
    used = _hosts_using(hosts_dir)
    records = []
    for name in _profile_dirs(src, cache):
        d = os.path.join(src, name)
        info = cache.get(name, {})
        urls = _sqlite_count(
            os.path.join(d, "History"),
            "select count(*) from urls where url like '%muse.ai%'",
        )
        session = _sqlite_count(
            os.path.join(d, "Cookies"),
            "select count(*) from cookies where host_key like '%muse.ai%' "
            "and (expires_utc = 0 or expires_utc > ?)",
            (now,),
        )
        emails = []
        for mail in [info.get("user_name")] + _account_emails(d):
            if mail and mail not in emails:
                emails.append(mail)
        urls = urls or 0
        # session = None -> khong doc duoc Cookies (profile chua tung mo Chrome?)
        # KHONG phai bang 0: "khong biet" va "da logout" la 2 trang thai khac nhau.
        known = session is not None
        session = session or 0
        records.append(
            {
                "profile_dir": name,
                "display_name": info.get("name") or name,
                "email": emails[0] if emails else "",
                "emails": emails,
                "muse_urls": urls,
                "muse_session": session if known else None,
                "logged_in": (session > 0) if known else None,
                "has_muse": session > 0 or urls > 0,
                "used_by": used.get(name, []),
            }
        )
    # Da co phien dang nhap truoc, sau do theo so URL muse.ai giam dan;
    # profile doc khong duoc cookie (unknown) nam cuoi.
    records.sort(
        key=lambda r: (
            0 if r["logged_in"] is True else (1 if r["logged_in"] is False else 2),
            -r["muse_urls"],
            r["profile_dir"],
        )
    )
    return records


def print_text(records):
    if not records:
        print("(khong tim thay Chrome profile nao)")
        return
    print(
        "%-14s %-18s %-34s %8s %7s %9s  %s"
        % ("PROFILE_DIR", "DISPLAY_NAME", "EMAIL", "MUSE_URLS", "SESSION", "LOGGED_IN", "USED_BY")
    )
    for r in records:
        logged = {True: "yes", False: "no", None: "?"}[r["logged_in"]]
        print(
            "%-14s %-18s %-34s %8d %7s %9s  %s"
            % (
                r["profile_dir"],
                r["display_name"],
                r["email"] or "-",
                r["muse_urls"],
                "-" if r["muse_session"] is None else r["muse_session"],
                logged,
                ",".join(r["used_by"]) or "-",
            )
        )


def main():
    ap = argparse.ArgumentParser(description="liet ke Chrome profile co muse.ai")
    ap.add_argument("--profile-src", default=DEFAULT_SRC, help="thu muc goc cua Chrome")
    ap.add_argument("--hosts-dir", default=os.environ.get("MUSE_BRIDGE_REPO_HOSTS", ""),
                    help="thu muc card host (.muse-hosts) de biet host nao dung profile nao")
    ap.add_argument("--json", action="store_true", help="in JSON (mac dinh)")
    ap.add_argument("--text", action="store_true", help="in bang chu, khong in JSON")
    ap.add_argument("--only-muse", action="store_true", help="chi giu profile co dau hieu muse.ai")
    args = ap.parse_args()

    if not args.hosts_dir:
        repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        args.hosts_dir = os.path.join(repo, ".muse-hosts")

    if not os.path.isdir(args.profile_src):
        print("[]" if not args.text else "(khong tim thay %s)" % args.profile_src)
        return 0

    records = scan(args.profile_src, args.hosts_dir)
    if args.only_muse:
        records = [r for r in records if r["has_muse"]]

    if args.text:
        print_text(records)
    else:
        print(json.dumps(records, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
