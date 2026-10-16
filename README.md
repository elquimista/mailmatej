# MailMateJ

A MailMate-style, native macOS mail client with JMAP support. Personal use; built without Xcode or an Apple Developer account.

## Layout

| Path | What |
|---|---|
| `Sources/JMAPKit` | JMAP client: session, batched requests with back-references, blob download, EventSource push. No UI or storage. |
| `Sources/MailStore` | SQLite (GRDB) source of truth: schema, list/correspondence/search queries, raw `.eml` store. Protocol-neutral. |
| `Sources/MailSync` | `JMAPAccountSync` (state strings + `/changes`) and `SyncCoordinator` (bounded concurrency, push, polling). |
| `Sources/MailMateJ` | AppKit app: sidebar, virtualized message lists, Correspondence layout, WebKit message view. SwiftUI only for the Add Account sheet. |
| `Sources/mmj-sync` | Headless sync CLI for development. |
| `dev/stalwart` | Local Stalwart server and a seeding script. |

## Build and run

Needs only the Command Line Tools (Swift 6.1+), macOS 15+.

```bash
scripts/bundle.sh            # release → build/MailMateJ.app
scripts/bundle.sh debug      # debug   → build/MailMateJ Dev.app
open build/MailMateJ.app
swift test
```

Add accounts with the toolbar button or **File → Add Account…**:
- **Fastmail**: an API token (Settings → Privacy & Security → API tokens).
- **Stalwart / other JMAP**: server host (autodiscovers via `/.well-known/jmap`), username, password.

The two builds are separate apps: different bundle IDs, icons (a tilted postage stamp; Dev is orange with a DEV label) and data folders, `~/Library/Application Support/MailMateJ` and `…/MailMateJ Dev`. `MMJ_DATA_DIR` overrides the folder. Secrets are in the login keychain. The icons are drawn by `scripts/make-icon.swift`; regenerate them with `scripts/make-icons.sh`.

### Keychain prompts after rebuilding

Ad-hoc signed apps are identified by a hash of their exact binary, so after every rebuild macOS asks again for keychain access. To fix this, create a signing certificate once. It's free and needs no Apple account:

1. Open **Keychain Access** and choose **Keychain Access → Certificate Assistant → Create a Certificate…**
2. Set Name to `MailMateJ Signing`, Identity Type to **Self Signed Root**, and Certificate Type to **Code Signing**. Click **Create**.
3. Rebuild with `scripts/bundle.sh`. It picks up the certificate automatically.
4. On the next launch, click **Always Allow** once. Later rebuilds keep that permission.

### Giving it to friends

Zip `build/MailMateJ.app` and send it. On first launch macOS blocks it. They open it once, then go to System Settings → Privacy & Security → **Open Anyway**. Alternatively they run `xattr -dr com.apple.quarantine MailMateJ.app`.

## Local dev server

```bash
cd dev/stalwart && docker compose up -d
```

First time only, complete Stalwart's bootstrap (fixed dev admin from `docker-compose.yml`) and seed:

```bash
curl -s -u admin:mmj-dev-admin -H 'Content-Type: application/json' http://localhost:8080/jmap -d '{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:Bootstrap/set",{"update":{"singleton":{"serverHostname":"mail.mmj.test","defaultDomain":"mmj.test","requestTlsCertificate":false,"generateDkimKeys":false}}},"c0"]]}'
```

The response contains the permanent admin. Save it as `user:secret` in `dev/stalwart/data/admin-credentials`. Then restart the server and seed it:

```bash
docker compose restart && python3 seed.py
```

`seed.py` creates alice/bob/carol (password `<name>-dev-pass`) with 300 messages each. `--accounts 100 --messages 50` is for scale tests, and `--live alice` delivers a message every 10 s for push testing.

Then:

```bash
scripts/run-dev.sh   # builds and launches MailMateJ Dev with the local accounts added
MMJ_PASSWORD=alice-dev-pass swift run mmj-sync --url http://localhost:8080 --user alice@mmj.test --watch
```

Stalwart always advertises `https://<hostname>` endpoints. For session URLs on localhost the client rewrites them onto the local origin. Debug builds also accept `MMJ_SNAPSHOT=/path.png` to save a window image a few seconds after launch.

## Status

- [x] M0 – JMAPKit, schema, initial + incremental sync, push
- [x] M1 – read-only window: unified mailboxes, account trees, virtualized lists, Correspondence layout, HTML/plain rendering with remote content blocked, search
- [ ] M2 – smart mailboxes (tables exist: `smart_mailbox`, `smart_membership`)
- [ ] M3 – actions (read/flag/move/delete) via the `pending_change` outbox; then rules
- [ ] M4 – compose and send (`EmailSubmission`)
- [ ] M5 – 100-account soak test, Instruments pass
- [ ] M6 – IMAP + SMTP backend
