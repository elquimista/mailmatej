#!/usr/bin/env python3
"""Seed the local dev Stalwart with test accounts and realistic-looking mail.

    python3 seed.py                      # alice, bob, carol with 300 messages each
    python3 seed.py --accounts 100 --messages 50   # user001..user100 (scale testing)
    python3 seed.py --live alice         # deliver one new message every 10 s (push testing)

Every account's password is "<name>-dev-pass". The JMAP URL for MailMateJ is http://localhost:8080.
Requires the server to be set up first: docker compose up -d, then the bootstrap step in README.md.
"""

import argparse
import base64
import json
import random
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from email.utils import format_datetime, make_msgid
from pathlib import Path

BASE = "http://localhost:8080"
DOMAIN = "mmj.test"
HERE = Path(__file__).parent
CORE, MAIL, BLOB = "urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail", "urn:ietf:params:jmap:blob"
ADMIN_USING = [CORE, "urn:stalwart:jmap"]

PEOPLE = [
    ("Ada Lovelace", "ada@analytical.example"), ("Grace Hopper", "grace@navy.example"),
    ("Linus Torvalds", "linus@kernel.example"), ("Margaret Hamilton", "margaret@apollo.example"),
    ("Dennis Ritchie", "dmr@bell-labs.example"), ("Barbara Liskov", "liskov@mit.example"),
    ("Ken Thompson", "ken@bell-labs.example"), ("Radia Perlman", "radia@spanning.example"),
    ("GitHub", "notifications@github.example"), ("Fastmail", "support@fastmail.example"),
    ("Hetzner Billing", "billing@hetzner.example"), ("Apple", "no_reply@apple.example"),
]
TOPICS = [
    "Quarterly planning", "Server migration", "Invoice {n}", "Re: lunch on Friday?", "Build failed on main",
    "Your receipt #{n}", "Design review notes", "[mailmatej] Issue #{n}: JMAP push drops", "Weekend hike",
    "Contract renewal", "Conference talk proposal", "Password reset requested", "Release v0.{n}",
]
BODIES = [
    "Hi,\n\nFollowing up on our conversation — could you take a look before Thursday?\n\nThanks!",
    "Hello,\n\nAttached are the numbers you asked for. Let me know if anything looks off.\n\nBest,",
    "Quick note: the deploy went fine, no errors in the logs.\n\nCheers",
    "Hey!\n\nAre we still on for this weekend? Weather looks good.\n\n:)",
]


def auth_header(user, password):
    return "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()


def jmap(auth, using, calls):
    body = json.dumps({"using": using, "methodCalls": calls}).encode()
    req = urllib.request.Request(f"{BASE}/jmap/", data=body, method="POST",
                                 headers={"Authorization": auth, "Content-Type": "application/json"})
    with urllib.request.urlopen(req) as r:
        return {c[2]: c[1] for c in json.load(r)["methodResponses"]}


def admin_auth():
    user, password = (HERE / "data" / "admin-credentials").read_text().strip().split(":", 1)
    return auth_header(user, password)


def ensure_user(name):
    res = jmap(admin_auth(), ADMIN_USING, [["x:Account/set", {"create": {"u": {
        "@type": "User", "name": name, "domainId": domain_id(),
        "credentials": {"0": {"@type": "Password", "secret": f"{name}-dev-pass"}},
    }}}, "c0"]])["c0"]
    created = "u" in (res.get("created") or {})
    print(f"{'created' if created else 'exists '} {name}@{DOMAIN}")


_domain = None


def domain_id():
    global _domain
    if _domain is None:
        lst = jmap(admin_auth(), ADMIN_USING, [["x:Domain/get", {"ids": None}, "c0"]])["c0"]["list"]
        _domain = next(d["id"] for d in lst if d["name"] == DOMAIN)
    return _domain


def user_session(name):
    auth = auth_header(f"{name}@{DOMAIN}", f"{name}-dev-pass")
    req = urllib.request.Request(f"{BASE}/.well-known/jmap", headers={"Authorization": auth})
    with urllib.request.urlopen(req) as r:
        session = json.load(r)
    return auth, session["primaryAccounts"][MAIL]


def mailboxes(auth, account):
    res = jmap(auth, [CORE, MAIL], [["Mailbox/get", {"accountId": account, "ids": None}, "c0"]])
    boxes = {(m["role"] or m["name"]).lower(): m["id"] for m in res["c0"]["list"]}
    missing = [n for n in ("Projects", "Receipts") if n.lower() not in boxes]
    if missing:
        res = jmap(auth, [CORE, MAIL], [["Mailbox/set", {"accountId": account, "create": {
            n: {"name": n, "parentId": None} for n in missing}}, "c0"]])
        for n, m in (res["c0"].get("created") or {}).items():
            boxes[n.lower()] = m["id"]
    return boxes


def make_message(me, when, outgoing, person, subject, in_reply_to=None):
    sender = f"{me[0]} <{me[1]}>" if outgoing else f"{person[0]} <{person[1]}>"
    rcpt = f"{person[0]} <{person[1]}>" if outgoing else f"{me[0]} <{me[1]}>"
    msgid = make_msgid(domain="seed.mmj.test")
    lines = [f"From: {sender}", f"To: {rcpt}", f"Subject: {subject}", f"Date: {format_datetime(when)}",
             f"Message-ID: {msgid}", "MIME-Version: 1.0"]
    if in_reply_to:
        lines += [f"In-Reply-To: {in_reply_to}", f"References: {in_reply_to}"]
    text = random.choice(BODIES) + f"\n{me[0] if outgoing else person[0].split()[0]}"
    if random.random() < 0.4:
        html = "<html><body style='font-family:-apple-system'>" + "".join(
            f"<p>{p}</p>" for p in text.split("\n\n")) + "<img src='https://tracker.example/pixel.gif'></body></html>"
        b = "mmjboundary"
        lines += [f'Content-Type: multipart/alternative; boundary="{b}"', "", f"--{b}",
                  "Content-Type: text/plain; charset=utf-8", "", text, f"--{b}",
                  "Content-Type: text/html; charset=utf-8", "", html, f"--{b}--", ""]
    else:
        lines += ["Content-Type: text/plain; charset=utf-8", "", text, ""]
    return "\r\n".join(lines), msgid


def import_batch(auth, account, items):
    """items: list of (raw, mailboxIds, keywords, receivedAt)."""
    blobs = {f"b{i}": {"data": [{"data:asText": raw}], "type": "message/rfc822"} for i, (raw, *_) in enumerate(items)}
    emails = {f"e{i}": {"blobId": f"#b{i}", "mailboxIds": {m: True for m in mbs}, "keywords": kw,
                        "receivedAt": at.strftime("%Y-%m-%dT%H:%M:%SZ")}
              for i, (_, mbs, kw, at) in enumerate(items)}
    res = jmap(auth, [CORE, MAIL, BLOB], [
        ["Blob/upload", {"accountId": account, "create": blobs}, "c0"],
        ["Email/import", {"accountId": account, "emails": emails}, "c1"],
    ])
    failed = res["c1"].get("notCreated") or {}
    if failed:
        print("  import errors:", list(failed.values())[:2])
    return len(res["c1"].get("created") or {})


def seed_user(name, count):
    auth, account = user_session(name)
    boxes = mailboxes(auth, account)
    me = (name.capitalize(), f"{name}@{DOMAIN}")
    now = datetime.now(timezone.utc)
    items, threads = [], []
    for n in range(count):
        when = now - timedelta(minutes=random.randint(5, 60 * 24 * 730))
        person = random.choice(PEOPLE)
        outgoing = random.random() < 0.2
        if threads and random.random() < 0.3:
            subject, parent, person = random.choice(threads)
            subject = subject if subject.startswith("Re:") else "Re: " + subject
        else:
            subject, parent = random.choice(TOPICS).format(n=random.randint(100, 9999)), None
        raw, msgid = make_message(me, when, outgoing, person, subject, parent)
        threads.append((subject, msgid, person))
        if outgoing:
            mbs, kw = [boxes["sent"]], {"$seen": True}
        else:
            target = random.choices(["inbox", "archive", "projects", "receipts"], [6, 3, 1, 1])[0]
            mbs = [boxes.get(target, boxes["inbox"])]
            kw = {}
            if random.random() < 0.75 or target != "inbox":
                kw["$seen"] = True
            if random.random() < 0.08:
                kw["$flagged"] = True
        items.append((raw, mbs, kw, when))
    imported = 0
    for i in range(0, len(items), 50):
        imported += import_batch(auth, account, items[i:i + 50])
    print(f"  {name}: imported {imported} messages")


def live(name):
    auth, account = user_session(name)
    boxes = mailboxes(auth, account)
    me = (name.capitalize(), f"{name}@{DOMAIN}")
    while True:
        person = random.choice(PEOPLE)
        raw, _ = make_message(me, datetime.now(timezone.utc), False, person, random.choice(TOPICS).format(n=random.randint(1, 999)))
        import_batch(auth, account, [(raw, [boxes["inbox"]], {}, datetime.now(timezone.utc))])
        print(f"{datetime.now():%H:%M:%S} delivered mail from {person[0]} to {name}")
        time.sleep(10)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--accounts", type=int, help="create userNNN accounts instead of alice/bob/carol")
    p.add_argument("--messages", type=int, default=300)
    p.add_argument("--live", metavar="USER")
    args = p.parse_args()
    random.seed(42)
    if args.live:
        return live(args.live)
    names = [f"user{i:03}" for i in range(1, args.accounts + 1)] if args.accounts else ["alice", "bob", "carol"]
    for name in names:
        ensure_user(name)
        seed_user(name, args.messages)


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as e:
        print("HTTP", e.code, e.read().decode()[:500])
        raise SystemExit(1)
