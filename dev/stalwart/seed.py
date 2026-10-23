#!/usr/bin/env python3
"""Seed the local dev Stalwart with test accounts and realistic-looking mail.

    python3 seed.py                      # alice, bob, carol with 300 messages each
    python3 seed.py --accounts 100 --messages 50   # user001..user100 (scale testing)
    python3 seed.py --live alice         # deliver one new message every 10 s (push testing)
    python3 seed.py --rich alice         # add messages with embedded, remote and tracking images

Every account's password is "<name>-dev-pass". The JMAP URL for MailMateJ is http://localhost:18080.
Requires the server to be set up first: docker compose up -d, then the bootstrap step in README.md.
"""

import argparse
import base64
import json
import random
import struct
import time
import zlib
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from email.utils import format_datetime, make_msgid
from pathlib import Path

BASE = "http://localhost:18080"
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


def png(width, height, rgb):
    """A solid-color PNG, so the embedded-image test needs no files."""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    rows = b"".join(b"\x00" + bytes(rgb) * width for _ in range(height))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def rich(name):
    """Messages for checking image handling: embedded (cid:), remote, insecure, tracker and 1x1 pixel."""
    auth, account = user_session(name)
    inbox = mailboxes(auth, account)["inbox"]
    me = f"{name.capitalize()} <{name}@{DOMAIN}>"
    now = datetime.now(timezone.utc)
    logo = base64.encodebytes(png(160, 48, (30, 90, 200))).decode()

    embedded = "\r\n".join([
        "From: Ashley Recruiter <ashley@trova.example>", f"To: {me}", "Subject: Embedded logo test",
        f"Date: {format_datetime(now - timedelta(minutes=1))}", f"Message-ID: {make_msgid(domain='seed.mmj.test')}",
        "MIME-Version: 1.0", 'Content-Type: multipart/related; boundary="rel"', "",
        "--rel", "Content-Type: text/html; charset=utf-8", "",
        "<p>I just reminded him to send it out :)</p><p>With kindness,<br>Ashley</p>"
        '<img src="cid:trova-logo@trova.example" alt="Trova logo">',
        "--rel", "Content-Type: image/png; name=logo.png", "Content-Transfer-Encoding: base64",
        "Content-ID: <trova-logo@trova.example>", "Content-Disposition: inline; filename=logo.png", "", logo,
        "--rel--", ""])

    def newsletter(sender, subject, minutes):
        html = (
            "<h2>Weekly picks</h2>"
            '<img src="https://www.w3.org/Icons/w3c_home.png" alt="remote 1">'
            '<img src="https://www.w3.org/Icons/valid-html401.png" alt="remote 2">'
            '<img src="http://insecure.example.com/banner.png" alt="insecure">'
            '<img src="https://us1.list-manage.com/track/open.php?u=1&id=2" alt="">'
            '<img src="https://shop.example.com/open-pixel.png" width="1" height="1" alt="">'
            "<p>Thanks for reading.</p>")
        return "\r\n".join([
            f"From: {sender}", f"To: {me}", f"Subject: {subject}",
            f"Date: {format_datetime(now - timedelta(minutes=minutes))}",
            f"Message-ID: {make_msgid(domain='seed.mmj.test')}", "MIME-Version: 1.0",
            "Content-Type: text/html; charset=utf-8", "", html, ""])

    job_alert_html = (
        "<style>td, span {font-family: Arial, sans-serif !important;} a {text-decoration: none;font-weight: bold;}</style>"
        '<table style="width:600px;margin:0 auto"><tr><td><img alt="" src="https://cdn.example.com/brand-logo.png" '
        'width="60" height="150"></td></tr>'
        '<tr><td style="color:#555;font-size:13px">Remote .net web developer jobs — <a href="https://example.com">edit settings</a></td></tr>'
        '<tr><td style="font-size:22px;font-weight:700;padding:20px 0">Your Job Alerts for Thursday, October 15</td></tr>'
        '<tr><td><a href="https://example.com/job/1" style="text-decoration:none"><table><tr>'
        '<td rowspan=2 style="padding:0 8px 0 4px"><img alt="LE" src="https://cdn.example.com/logo.webp" width="32" height="32" '
        'style="width:32px;height:32px;display:block;object-fit:contain;background-color:#fff;"></td>'
        '<td style="color:#393939;font-weight:700;font-size:16px;padding:0">Guidehouse</td></tr>'
        '<tr><td style="padding:4px 0px 0px 0px;color:#0682E0;font-weight:700;font-size:16px"> Remote Developer - .NET </td></tr>'
        "</table></a></td></tr></table>")
    job_alert = "\r\n".join([
        "From: Job Alerts <jobs@alerts.example>", f"To: {me}", "Subject: Job alert layout test",
        f"Date: {format_datetime(now - timedelta(minutes=4))}", f"Message-ID: {make_msgid(domain='seed.mmj.test')}",
        "MIME-Version: 1.0", "Content-Type: text/html; charset=utf-8", "", job_alert_html, ""])

    items = [
        (embedded, [inbox], {}, now - timedelta(minutes=1)),
        (job_alert, [inbox], {}, now - timedelta(minutes=4)),
        (newsletter("Shop News <news@shop.example>", "Remote images test", 2), [inbox], {}, now - timedelta(minutes=2)),
        (newsletter("Shop Deals <deals@shop.example>", "Remote images test (same domain)", 3), [inbox], {},
         now - timedelta(minutes=3)),
    ]
    print(f"  {name}: imported {import_batch(auth, account, items)} rich messages")


def attachments(name):
    """A message with file attachments next to an embedded image, for the attachment row."""
    auth, account = user_session(name)
    inbox = mailboxes(auth, account)["inbox"]
    me = f"{name.capitalize()} <{name}@{DOMAIN}>"
    now = datetime.now(timezone.utc)
    logo = base64.encodebytes(png(120, 36, (200, 60, 40))).decode()
    chart = base64.encodebytes(png(400, 240, (40, 160, 90))).decode()
    csv = base64.encodebytes(b"month,revenue\nJuly,1200\nAugust,1350\nSeptember,1610\n").decode()
    notes = base64.encodebytes(("Meeting notes\n\n" + "Discussed the Q3 numbers.\n" * 40).encode()).decode()
    raw = "\r\n".join([
        "From: Ada Lovelace <ada@analytical.example>", f"To: {me}", "Subject: Q3 numbers with attachments",
        f"Date: {format_datetime(now)}", f"Message-ID: {make_msgid(domain='seed.mmj.test')}",
        "MIME-Version: 1.0", 'Content-Type: multipart/mixed; boundary="mix"', "",
        "--mix", 'Content-Type: multipart/related; boundary="rel"', "",
        "--rel", "Content-Type: text/html; charset=utf-8", "",
        '<p>Hi,</p><p>The Q3 numbers are attached, plus the chart and my notes.</p>'
        '<img src="cid:sig-logo@analytical.example" alt="Analytical logo"><p>Ada</p>',
        "--rel", "Content-Type: image/png; name=logo.png", "Content-Transfer-Encoding: base64",
        "Content-ID: <sig-logo@analytical.example>", "Content-Disposition: inline; filename=logo.png", "", logo,
        "--rel--",
        "--mix", 'Content-Type: text/csv; name="Q3 revenue.csv"', "Content-Transfer-Encoding: base64",
        'Content-Disposition: attachment; filename="Q3 revenue.csv"', "", csv,
        "--mix", 'Content-Type: image/png; name="Revenue chart.png"', "Content-Transfer-Encoding: base64",
        'Content-Disposition: attachment; filename="Revenue chart.png"', "", chart,
        "--mix", 'Content-Type: text/plain; name="Meeting notes.txt"', "Content-Transfer-Encoding: base64",
        'Content-Disposition: attachment; filename="Meeting notes.txt"', "", notes,
        "--mix--", ""])
    print(f"  {name}: imported {import_batch(auth, account, [(raw, [inbox], {}, now)])} attachment message")


def invite(name):
    """An interview invite as recruiters send them: text, HTML and an unnamed text/calendar part side by
    side, plus a named .docx attachment."""
    auth, account = user_session(name)
    inbox = mailboxes(auth, account)["inbox"]
    me = f"{name}@{DOMAIN}"
    now = datetime.now(timezone.utc)
    ics = "\r\n".join([
        "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//MailMateJ seed//EN", "METHOD:REQUEST", "BEGIN:VEVENT",
        f"UID:{make_msgid(domain='seed.mmj.test')[1:-1]}", "DTSTAMP:20261014T160000Z",
        "DTSTART:20261020T150000Z", "DTEND:20261020T153000Z", "SUMMARY:Interview", "END:VEVENT", "END:VCALENDAR"])
    docx = base64.encodebytes(b"PK\x03\x04 not really a docx, just bytes for the seed").decode()
    raw = "\r\n".join([
        "From: Kim Recruiter <kim.recruiter@staffing.example>", f"To: {me} <{me}>",
        "Subject: Interview invite with calendar", f"Date: {format_datetime(now)}",
        f"Message-ID: {make_msgid(domain='seed.mmj.test')}", "MIME-Version: 1.0",
        'Content-Type: multipart/mixed; boundary="mix"', "",
        "--mix", 'Content-Type: multipart/alternative; boundary="alt"', "",
        "--alt", "Content-Type: text/plain; charset=utf-8", "", "Please find the interview details attached.",
        "--alt", "Content-Type: text/html; charset=utf-8", "", "<p>Please find the interview details attached.</p>",
        "--alt", 'Content-Type: text/calendar; charset=utf-8; method=REQUEST', "", ics,
        "--alt--",
        "--mix", 'Content-Type: application/vnd.openxmlformats-officedocument.wordprocessingml.document; name="Resume.docx"',
        "Content-Transfer-Encoding: base64", 'Content-Disposition: attachment; filename="Resume.docx"', "", docx,
        "--mix--", ""])
    print(f"  {name}: imported {import_batch(auth, account, [(raw, [inbox], {}, now)])} invite message")


def thread(name):
    """A three-message conversation in the inbox (the first one answered), for the threaded list."""
    auth, account = user_session(name)
    inbox = mailboxes(auth, account)["inbox"]
    me = f"{name.capitalize()} <{name}@{DOMAIN}>"
    now = datetime.now(timezone.utc)
    ids = [make_msgid(domain="seed.mmj.test") for _ in range(3)]
    items = []
    for i, (who, subject, text) in enumerate([
        ("Grace Hopper <grace@navy.example>", "Thread test", "Shall we meet on Friday?"),
        ("Grace Hopper <grace@navy.example>", "Re: Thread test", "Or Monday, if Friday doesn't work."),
        ("Ada Lovelace <ada@analytical.example>", "Re: Thread test", "Monday works for me too."),
    ]):
        refs = ids[:i]
        headers = [f"From: {who}", f"To: {me}", f"Subject: {subject}",
                   f"Date: {format_datetime(now - timedelta(minutes=30 - i * 10))}", f"Message-ID: {ids[i]}"]
        if refs:
            headers += [f"In-Reply-To: {refs[-1]}", f"References: {' '.join(refs)}"]
        raw = "\r\n".join(headers + ["MIME-Version: 1.0", "Content-Type: text/plain; charset=utf-8", "", text, ""])
        keywords = {"$seen": True, "$answered": True} if i == 0 else {}
        items.append((raw, [inbox], keywords, now - timedelta(minutes=30 - i * 10)))
    print(f"  {name}: imported {import_batch(auth, account, items)} thread messages")


def undisclosed(name):
    """A recruiter's mass mail: To undisclosed-recipients, the user in Bcc, and an HTML link without colours."""
    auth, account = user_session(name)
    inbox = mailboxes(auth, account)["inbox"]
    now = datetime.now(timezone.utc)
    html = ("<p>Hi,</p><p>This is a remote contract opportunity.</p>"
            '<p><b>Apply Here:</b> <a href="https://jobs.example.com/post/6634c1b6-553f-4d60-a692-be00546">'
            "Software engineering ( Backend)</a></p>")
    raw = "\r\n".join([
        "From: Drashti Patel <drashti.hiring@recruit.example>", "To: undisclosed-recipients:;",
        f"Bcc: {name}@{DOMAIN}", "Subject: Software Engineering (Backend) - Remote Contract Opportunity",
        f"Date: {format_datetime(now)}", f"Message-ID: {make_msgid(domain='seed.mmj.test')}", "MIME-Version: 1.0",
        "Content-Type: text/html; charset=utf-8", "", html, ""])
    print(f"  {name}: imported {import_batch(auth, account, [(raw, [inbox], {}, now)])} undisclosed-recipients message")


def reply(name):
    """A new reply to the user's oldest inbox message, as if just delivered: its thread should come to the new mail."""
    auth, account = user_session(name)
    inbox = mailboxes(auth, account)["inbox"]
    r = jmap(auth, ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"], [
        ["Email/query", {"accountId": account, "filter": {"inMailbox": inbox}, "sort": [{"property": "receivedAt"}],
                         "limit": 1}, "q"],
        ["Email/get", {"accountId": account, "#ids": {"resultOf": "q", "name": "Email/query", "path": "/ids"},
                       "properties": ["messageId", "subject", "from"]}, "g"]])
    old = r["g"]["list"][0]
    parent = old["messageId"][0]
    who = old["from"][0]
    now = datetime.now(timezone.utc)
    raw = "\r\n".join([
        f"From: {who.get('name') or ''} <{who['email']}>", f"To: {name}@{DOMAIN}", f"Subject: Re: {old['subject']}",
        f"Date: {format_datetime(now)}", f"Message-ID: {make_msgid(domain='seed.mmj.test')}",
        f"In-Reply-To: <{parent}>", f"References: <{parent}>", "MIME-Version: 1.0",
        "Content-Type: text/plain; charset=utf-8", "", "A new reply to an old conversation.", ""])
    print(f"  {name}: imported {import_batch(auth, account, [(raw, [inbox], {}, now)])} reply to {old['subject']!r}")


def live_many(count, every):
    """Delivers a message to a random one of user001..userNNN every `every` seconds, for soak tests."""
    sessions = {}
    while True:
        name = f"user{random.randint(1, count):03}"
        if name not in sessions:
            auth, account = user_session(name)
            sessions[name] = (auth, account, mailboxes(auth, account))
        auth, account, boxes = sessions[name]
        me = (name.capitalize(), f"{name}@{DOMAIN}")
        person = random.choice(PEOPLE)
        raw, _ = make_message(me, datetime.now(timezone.utc), False, person, random.choice(TOPICS).format(n=random.randint(1, 999)))
        import_batch(auth, account, [(raw, [boxes["inbox"]], {}, datetime.now(timezone.utc))])
        print(f"{datetime.now():%H:%M:%S} delivered to {name}", flush=True)
        time.sleep(every)


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
    p.add_argument("--rich", metavar="USER")
    p.add_argument("--attachments", metavar="USER")
    p.add_argument("--invite", metavar="USER")
    p.add_argument("--thread", metavar="USER")
    p.add_argument("--undisclosed", metavar="USER")
    p.add_argument("--reply", metavar="USER")
    p.add_argument("--live-many", type=float, metavar="SECONDS", help="deliver to random userNNN accounts this often")
    args = p.parse_args()
    random.seed(42)
    if args.live:
        return live(args.live)
    if args.rich:
        return rich(args.rich)
    if args.attachments:
        return attachments(args.attachments)
    if args.invite:
        return invite(args.invite)
    if args.thread:
        return thread(args.thread)
    if args.undisclosed:
        return undisclosed(args.undisclosed)
    if args.reply:
        return reply(args.reply)
    if args.live_many:
        return live_many(args.accounts or 100, args.live_many)
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
