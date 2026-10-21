# MailMateJ

A MailMate-style, native macOS mail client with JMAP support. Personal use; built without Xcode or an Apple Developer account.

## Layout

| Path | What |
|---|---|
| `Sources/JMAPKit` | JMAP client: session, batched requests with back-references, blob upload and download, WebSocket and EventSource push. No UI or storage. |
| `Sources/MailStore` | SQLite (GRDB) source of truth: schema, list/correspondence/search queries, raw `.eml` store. Protocol-neutral. |
| `Sources/MailSync` | `JMAPAccountSync` (state strings + `/changes`, full download, message changes, sending) and `SyncCoordinator` (bounded concurrency, push, polling). |
| `Sources/MailMateJ` | AppKit app: sidebar, virtualized and threaded message lists, Correspondence layout, WebKit message view, composer, account and mailbox settings. SwiftUI only for the Settings window's Counters pane. |
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

Add accounts with the toolbar button or **File → Add Account…**, which opens a JMAP version of MailMate's account settings:
- **Stalwart / other JMAP**: the server's host name (autodiscovers via `/.well-known/jmap`; Port and Require SSL for anything unusual), user name and password.
- **Fastmail**: `fastmail.com` as the server and an API token (Settings → Privacy & Security → API tokens) as the password.

Double-click an account in the sidebar (or **Edit Account…** in its context menu) to change it; the password is kept unless a new one is typed. **Email Address(es)** takes `address`, `<address>` or `Name <address>`, comma-separated. Those addresses are the From choices, in that order; ones the server has no identity for are sent through the account's own identity.

The two builds are separate apps: different bundle IDs, icons (a tilted postage stamp; Dev is orange with a DEV label) and data folders, `~/Library/Application Support/MailMateJ` and `…/MailMateJ Dev`. `MMJ_DATA_DIR` overrides the folder. Secrets are in the login keychain. The icons are drawn by `scripts/make-icon.swift`; regenerate them with `scripts/make-icons.sh`.

### Keychain prompts after rebuilding

macOS ties keychain access to an app's Team ID. Without one, every new build counts as a new app, and the keychain asks for your password once per build. `scripts/bundle.sh` signs with the best identity it finds:

1. **Apple Development certificate (recommended, free).** It needs a free Apple ID in Xcode and no paid membership. It gives the app a Team ID, so after one last "Always Allow", rebuilds no longer prompt.
   1. Install Xcode from the Mac App Store and open it once.
   2. In Xcode, go to **Settings → Accounts**, click **+**, choose **Apple ID** and sign in. This creates a "Personal Team".
   3. Select the team and click **Manage Certificates…**. Then click **+** and choose **Apple Development**.
   4. Run `scripts/bundle.sh`. It should report `Team ID …`.
2. **Self-signed "MailMateJ Signing" certificate.** It's stable, but the keychain still asks once per build.
3. **Ad hoc**, used when no certificate is found.

`MMJ_SIGN_IDENTITY` overrides the choice. Signing with an Apple Development certificate doesn't change how friends open the app: they still need "Open Anyway".

### Giving it to friends

Zip `build/MailMateJ.app` and send it. On first launch macOS blocks it. They open it once, then go to System Settings → Privacy & Security → **Open Anyway**. Alternatively they run `xattr -dr com.apple.quarantine MailMateJ.app`.

## Local dev server

```bash
cd dev/stalwart && docker compose up -d
```

First time only, complete Stalwart's bootstrap (fixed dev admin from `docker-compose.yml`) and seed:

```bash
curl -s -u admin:mmj-dev-admin -H 'Content-Type: application/json' http://localhost:18080/jmap -d '{"using":["urn:ietf:params:jmap:core","urn:stalwart:jmap"],"methodCalls":[["x:Bootstrap/set",{"update":{"singleton":{"serverHostname":"mail.mmj.test","defaultDomain":"mmj.test","requestTlsCertificate":false,"generateDkimKeys":false}}},"c0"]]}'
```

The server listens on 127.0.0.1 only: the admin and test passwords are in this repo. The response contains the permanent admin. Save it as `user:secret` in `dev/stalwart/data/admin-credentials`. Then restart the server and seed it:

```bash
docker compose restart && python3 seed.py
```

`seed.py` creates alice/bob/carol (password `<name>-dev-pass`) with 300 messages each. `--accounts 100 --messages 50` is for scale tests, and `--live alice` delivers a message every 10 s for push testing. Test messages for one user: `--rich` (embedded, remote and tracker images), `--attachments`, `--invite` (an unnamed calendar part), `--thread` (a three-message conversation), `--undisclosed` (To `undisclosed-recipients:;`, the user in Bcc, an HTML link) and `--reply` (a new reply to the user's oldest inbox message).

Then:

```bash
scripts/run-dev.sh   # builds and launches MailMateJ Dev with the local accounts added
MMJ_PASSWORD=alice-dev-pass swift run mmj-sync --url http://localhost:18080 --user alice@mmj.test --watch
```

Stalwart always advertises `https://<hostname>` endpoints. For session URLs on localhost the client rewrites them onto the local origin. Debug builds also accept `MMJ_SNAPSHOT=/path.png` to save a window image a few seconds after launch.

## Status

- [x] M0 – JMAPKit, schema, initial + incremental sync, push (WebSocket, EventSource fallback, fast polling when push stalls), full download of every message
- [x] M1 – window: unified mailboxes with submailboxes, account trees, virtualized lists threaded by reply headers (a closed thread shows and sorts by its newest message), Correspondence layout, HTML/plain rendering with remote content blocked and a link preview on hover, attachment rows (Quick Look, save, drag out), search, Dock counters, MailMate's toolbar and Go to Mailbox panel
- [x] M2 – smart mailboxes: unified mailboxes' submailboxes, and user-defined smart mailboxes (mailboxes, nested conditions compiled to SQL, submailboxes split by a field) in MailMate's mailbox editor
- [x] M3 – actions: archive, junk, delete, read/unread, flag and move (to any account; the copy is confirmed before the original goes), instant with undo, plus Gmail+Vimium keys and MailMate's Message menu; rules on new mail (move/copy, delete, redirect, forward, keywords); changes made while a server can't be reached are queued (`change_queue`) and made in order before the account next syncs
- [x] M4 – compose and send (`EmailSubmission`): new message, reply, reply all, forward with attachments, Bcc, several From addresses per account
- [ ] M5 – 100-account soak test, Instruments pass
- [ ] M6 – IMAP + SMTP backend
