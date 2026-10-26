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

- **Gmail**: `gmail.com` as the server, then **Sign In…**: Google's sign-in opens in your browser. This needs a Google OAuth client built into the app (see [Gmail](#gmail)). Gmail accounts can be added, but don't sync yet.

Double-click an account in the sidebar (or **Edit Account…** in its context menu) to change it; the password is kept unless a new one is typed. **Email Address(es)** takes `address`, `<address>` or `Name <address>`, comma-separated. Those addresses are the From choices, in that order; ones the server has no identity for are sent through the account's own identity. Their name is the account's **Full Name**, whatever name the server's identity has; a name given in Email Address(es) wins for its address.

The two builds are separate apps: different bundle IDs, icons (a tilted postage stamp; Dev is orange with a DEV label) and data folders, `~/Library/Application Support/MailMateJ` and `…/MailMateJ Dev`. `MMJ_DATA_DIR` overrides the folder. Secrets are in the login keychain. The icons are drawn by `scripts/make-icon.swift`; regenerate them with `scripts/make-icons.sh`.

### Gmail

Gmail accounts sign in with Google (OAuth) and use the Gmail API. Google needs an OAuth client for the app, which you create once in Google Cloud. It's free.

1. Open [console.cloud.google.com](https://console.cloud.google.com), sign in, and create a project (for example "MailMateJ").
2. Go to **APIs & Services → Library**, find **Gmail API** and click **Enable**.
3. Go to **Google Auth Platform** (APIs & Services → OAuth consent screen) and click **Get started**:
   - App name "MailMateJ" and your address as the support email.
   - Audience: **External**.
   - Your address as the contact email. Accept the policy and click **Create**.
4. Under **Data Access**, click **Add or remove scopes**. Under "Manually add scopes", enter `https://mail.google.com/`, click **Add to table**, then **Update** and **Save**.
5. Under **Clients**, click **Create client**, choose **Desktop app**, name it and click **Create**. Download its JSON file and save it in this folder as `google-oauth-client.json`. Git ignores that file.
6. Under **Audience**, click **Publish app** and confirm, so the status reads **In production**. While it says **Testing**, Google ends each sign-in after 7 days.
7. Run `scripts/bundle.sh` (and `scripts/bundle.sh debug`). The client is built into the app from that file.

Then add the account: **File → Add Account…**, `gmail.com` as the server, and **Sign In…**. Because the app isn't verified by Google, the sign-in page warns "Google hasn't verified this app". Click **Advanced → Go to MailMateJ (unsafe)**, then allow access. That's expected for a personal client. An unverified app can be used by at most 100 Google accounts in total, which includes friends using your build. The app keeps the sign-in (a refresh token) in the keychain.

For releases built on GitHub, add the JSON file's contents as the repository secret `GOOGLE_OAUTH_CLIENT_JSON`. Google treats a desktop app's client secret as public, so shipping it inside the app is normal.

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

### Releases

Pushing a tag builds the release app on GitHub Actions (`.github/workflows/release.yml`) and publishes it, zipped, as that tag's release: `v1.2.0` becomes version 1.2.0, and a tag with a hyphen (`v1.3.0-beta1`) a pre-release.

```bash
git tag v0.2.0 && git push origin v0.2.0
```

To sign releases with your Apple Development certificate (so the keychain keeps trusting updates), add two repository secrets: `MACOS_CERTIFICATE_P12`, the base64 of the certificate and its private key exported from Keychain Access as a .p12 (`base64 -i cert.p12 | pbcopy`), and `MACOS_CERTIFICATE_PASSWORD`, the export password. Without them releases are signed ad hoc.

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

`seed.py` creates alice/bob/carol (password `<name>-dev-pass`) with 300 messages each. `--accounts 100 --messages 50` is for scale tests, and `--live alice` delivers a message every 10 s for push testing. Test messages for one user: `--rich` (embedded, remote and tracker images), `--attachments`, `--invite` (an unnamed calendar part), `--thread` (a three-message conversation), `--undisclosed` (To `undisclosed-recipients:;`, the user in Bcc, an HTML link) and `--reply` (a new reply to the user's oldest inbox message). For scale tests: `--accounts 100 --messages 300` seeds user001…user100, and `--accounts 100 --live-many 1` then delivers to a random one of them every second; run the Dev app with them (`MMJ_DEV_ACCOUNTS=user001,…`, ideally with `MMJ_DATA_DIR` pointing at a scratch folder) and sample it with `scripts/soak-monitor.sh <data dir> [seconds]`, which prints messages stored and downloaded, memory, CPU, threads and connections as CSV.

Then:

```bash
scripts/run-dev.sh   # builds and launches MailMateJ Dev with the local accounts added
MMJ_PASSWORD=alice-dev-pass swift run mmj-sync --url http://localhost:18080 --user alice@mmj.test --watch
```

Stalwart always advertises `https://<hostname>` endpoints. For session URLs on localhost the client rewrites them onto the local origin. Debug builds also accept `MMJ_SNAPSHOT=/path.png` to save a window image a few seconds after launch.

## Status

- [x] M0 – JMAPKit, schema, initial + incremental sync, push (WebSocket, EventSource fallback, fast polling when push stalls), full download of every message
- [x] M1 – window: unified mailboxes with submailboxes, account trees, virtualized lists threaded by reply headers (a closed thread shows and sorts by its newest message), Correspondence layout, HTML/plain rendering with remote content blocked and a link preview on hover, attachment rows (Quick Look, save, drag out), search (from All Messages, staying on as you change mailbox), Thread and Correspondence results, each with MailMate's Details (its conditions, to edit) and Save (as a smart mailbox), Dock counters, MailMate's toolbar and Go to Mailbox panel; the sidebar reorders by dragging, renames with Return, and takes MailMate's per-mailbox Color (optionally in the message list) and Symbol
- [x] M2 – smart mailboxes: unified mailboxes' submailboxes (Flagged among them, and All / Junk / Deleted under All Messages), and user-defined smart mailboxes (mailboxes, nested conditions compiled to SQL — addresses, Subject, Date, Unquoted/Quoted Text, Content-Type, #Thread-Id and more — and submailboxes split by a field) in MailMate's mailbox editor
- [x] M3 – actions: archive, junk, delete, read/unread, flag and move (to any account; the copy is confirmed before the original goes), instant with undo, from the toolbar, Gmail+Vimium keys, MailMate's Message menu and the message context menu (Move to Archive, Move to/Out of Junk, Move to Mailbox…); rules on new mail (move/copy, delete, redirect, forward, keywords); changes made while a server can't be reached are queued (`change_queue`) and made in order before the account next syncs
- [x] M4 – compose and send (`EmailSubmission`): new message, reply, reply all, forward with attachments, Bcc, several From addresses per account; drafts saved in the account's Drafts a few seconds after each change (Save / Don't Save on closing, kept on quitting), reopened by double-clicking them with their Markdown, attachments and Bcc
- [x] M5 – 100-account soak test, Instruments pass: with 100 accounts and 30,000 messages (local Stalwart), metadata syncs in under 20 s and every message is downloaded in about 5½ min; idle at 0% CPU with a 70 MB footprint and one push connection per account; a 16,000-message threaded list reloads in about 120 ms off the main thread; 40 minutes of mail arriving every second showed no memory growth. Actions take rows out of the list at once rather than after the reload, archiving into an Archive the server has yet to create doesn't wait for it, quitting waits for changes still on their way to the servers (a progress window, then it quits by itself; "Quit Now" for a hung server), and messages a crash or Force Quit left without a mailbox are fetched again on sync

JMAP is what MailMateJ is built for. Later, nice to have: an IMAP + SMTP backend for servers without JMAP.
