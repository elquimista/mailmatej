import Foundation
import JMAPKit
import MailStore
import MailSync

// Headless sync for development:
//   MMJ_PASSWORD=… swift run mmj-sync --url http://localhost:18080 --user alice
//   MMJ_TOKEN=…    swift run mmj-sync --url https://api.fastmail.com/jmap/session
// Options: --db <dir> (default ./.dev-store), --watch (stay running on push), --name <account name>

func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

setvbuf(stdout, nil, _IOLBF, 0)
let env = ProcessInfo.processInfo.environment
guard let input = argument("--url"), let sessionURL = JMAPClient.sessionURL(from: input) else {
    fail("usage: mmj-sync --url <server or session URL> [--user <name>] [--db <dir>] [--watch]\n"
        + "       password in MMJ_PASSWORD, or API token in MMJ_TOKEN")
}

let credentials: Credentials
let authKind: AccountRecord.AuthKind
let username = argument("--user") ?? ""
if let token = env["MMJ_TOKEN"] {
    credentials = .bearer(token: token)
    authKind = .bearer
} else if let password = env["MMJ_PASSWORD"], !username.isEmpty {
    credentials = .basic(username: username, password: password)
    authKind = .basic
} else {
    fail("set MMJ_TOKEN, or pass --user and set MMJ_PASSWORD")
}

let directory = URL(fileURLWithPath: argument("--db") ?? ".dev-store", isDirectory: true)
let store = try MailStore(directory: directory)

let session = try await JMAPClient(sessionURL: sessionURL, credentials: credentials).fetchSession()
print("Session: \(session.username) — API \(session.apiUrl)")

var account =
    try store.accounts().first { $0.sessionURL == sessionURL.absoluteString && $0.username == session.username }
    ?? AccountRecord(
        name: argument("--name") ?? session.username, sessionURL: sessionURL.absoluteString,
        username: session.username, authKind: authKind)
account.remoteAccountId = session.primaryMailAccountId
try store.save(account)

let coordinator = SyncCoordinator(store: store, credentials: { _ in credentials }) { status in
    if case .failed(let why) = status.phase { print("✗ \(why)") }
}
try await coordinator.loadAccounts(push: false)

let clock = ContinuousClock()
let start = clock.now
let result = try await coordinator.syncNow(account.id)
let elapsed = clock.now - start
print("Synced \(account.name) in \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds]))): "
    + "\(result.mailboxes) mailbox changes, \(result.created) new, \(result.updated) updated, \(result.destroyed) removed")

let total = try store.messageIDs(scope: .account(account.id)).count
let inbox = try store.messageIDs(scope: .role("inbox")).count
print("Store: \(total) messages in account, \(inbox) in unified Inbox — \(directory.path)")

if CommandLine.arguments.contains("--watch") {
    print("Watching for push changes (Ctrl-C to stop)…")
    let engine = try JMAPAccountSync(account: account, credentials: credentials, store: store)
    for try await _ in try await engine.changeNotifications() {
        let r = try await engine.sync()
        print("\(Date().formatted(date: .omitted, time: .standard)) push → \(r.created) new, \(r.updated) updated, \(r.destroyed) removed")
    }
}
