import AppKit
import JMAPKit
import MailStore
import MailSync
import os

extension Notification.Name {
    /// Posted on the main thread (debounced) after synced data changed.
    static let mailStoreDidChange = Notification.Name("MailStoreDidChange")
    static let syncStatusDidChange = Notification.Name("SyncStatusDidChange")
}

struct AccountDraft {
    var name: String
    var sessionURL: URL
    var username: String
    var authKind: AccountRecord.AuthKind
    var secret: String
}

/// App-wide state shared by windows: the store, the sync coordinator and sync statuses.
@MainActor
final class AppModel {
    static private(set) var shared: AppModel!

    let store: MailStore
    let coordinator: SyncCoordinator
    private(set) var statuses: [String: AccountSyncStatus] = [:]
    private(set) var myAddresses: Set<String> = []
    private var observation: StoreObservation?
    private var refreshScheduled = false
    private(set) var dockCounters: DockCounters?

    static func bootstrap() throws {
        shared = try AppModel()
    }

    private init() throws {
        let env = ProcessInfo.processInfo.environment
        // Each build flavor keeps its own data: ~/Library/Application Support/<app name>.
        let directory = env["MMJ_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL.applicationSupportDirectory.appendingPathComponent(appName, isDirectory: true)
        store = try MailStore(directory: directory)
        coordinator = SyncCoordinator(
            store: store,
            credentials: Self.credentials(for:),
            onStatus: { status in
                Task { @MainActor in AppModel.shared?.statusChanged(status) }
            })
    }

    func start() {
        observation = store.observeChanges {
            Task { @MainActor in AppModel.shared?.scheduleRefresh() }
        }
        myAddresses = (try? store.myAddresses()) ?? []
        dockCounters = DockCounters(store: store)
        dockCounters?.update()
        #if DEBUG
            addDevAccountsIfRequested()
            if ProcessInfo.processInfo.environment["MMJ_KEYCHAIN_SELFTEST"] != nil { keychainSelfTest() }
        #endif
        Task { try? await coordinator.start() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in AppModel.shared?.syncAll() }
        }
    }

    func syncAll() {
        Task { await coordinator.syncAll() }
    }

    func sync(accountId: String) {
        Task { await coordinator.requestSync(accountId) }
    }

    var syncingCount: Int { statuses.values.filter { $0.phase == .syncing }.count }

    // MARK: Accounts

    func addAccount(_ draft: AccountDraft) async throws {
        let credentials: Credentials =
            switch draft.authKind {
            case .basic: .basic(username: draft.username, password: draft.secret)
            case .bearer: .bearer(token: draft.secret)
            }
        let session = try await JMAPClient(sessionURL: draft.sessionURL, credentials: credentials).fetchSession()
        guard let mailAccountId = session.primaryMailAccountId else {
            throw JMAPError.missingCapability(Capability.mail)
        }
        let record = AccountRecord(
            name: draft.name.isEmpty ? session.username : draft.name,
            sessionURL: draft.sessionURL.absoluteString,
            username: draft.authKind == .basic ? draft.username : session.username,
            authKind: draft.authKind, remoteAccountId: mailAccountId,
            sortOrder: (try store.accounts().map(\.sortOrder).max() ?? -1) + 1)
        try Keychain.set(draft.secret, account: record.id)
        try store.save(record)
        await coordinator.addAccount(record)
    }

    func removeAccount(id: String) {
        Task {
            await coordinator.removeAccount(id: id)
            try? store.deleteAccount(id: id)
            Keychain.delete(account: id)
            statuses.removeValue(forKey: id)
        }
    }

    /// What to show the user for an error: a plain sentence; debug builds append the raw error.
    static func describe(_ error: Error) -> String {
        #if DEBUG
            ErrorText.friendly(error) + "\n\n" + ErrorText.technical(error)
        #else
            ErrorText.friendly(error)
        #endif
    }

    /// The sidebar warning for an account that failed to sync, if any.
    func syncWarning(accountId: String) -> String? {
        guard let status = statuses[accountId], case .failed(let message) = status.phase else { return nil }
        #if DEBUG
            return status.errorDetail.map { message + "\n\n" + $0 } ?? message
        #else
            return message
        #endif
    }

    /// The message's raw .eml file on disk, downloading it from the server first if needed.
    func rawMessageURL(messageId: Int64) async throws -> URL {
        guard let detail = try store.detail(id: messageId) else { throw CocoaError(.fileNoSuchFile) }
        let url = store.blobs.url(accountId: detail.accountId, blobId: detail.blobId)
        if !FileManager.default.fileExists(atPath: url.path) {
            let data = try await coordinator.downloadBlob(
                accountId: detail.accountId, blobId: detail.blobId, type: "message/rfc822", name: "message.eml")
            try store.blobs.write(data, accountId: detail.accountId, blobId: detail.blobId)
        }
        return url
    }

    /// Selects the message's .eml file in Finder.
    func showInFinder(messageId: Int64, window: NSWindow?) {
        Task {
            do {
                let url = try await rawMessageURL(messageId: messageId)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn’t show this message in Finder."
                alert.informativeText = Self.describe(error)
                if let window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
            }
        }
    }

    /// The bytes of a message part (e.g. an embedded image), cached on disk after the first download.
    func partData(accountId: String, part: MessagePart) async throws -> Data {
        if let cached = store.blobs.readPart(accountId: accountId, blobId: part.blobId) { return cached }
        let data = try await coordinator.downloadBlob(
            accountId: accountId, blobId: part.blobId, type: part.type, name: part.name ?? "part")
        try? store.blobs.writePart(data, accountId: accountId, blobId: part.blobId)
        return data
    }

    func fetchBody(messageId: Int64, accountId: String) async throws -> MessageBody {
        try await coordinator.fetchBody(messageId: messageId, accountId: accountId)
    }

    // MARK: Private

    private var statusPostScheduled = false

    /// Stores the status and notifies the UI, at most twice a second (downloads report often).
    private func statusChanged(_ status: AccountSyncStatus) {
        statuses[status.accountId] = status
        guard !statusPostScheduled else { return }
        statusPostScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            statusPostScheduled = false
            NotificationCenter.default.post(name: .syncStatusDidChange, object: nil)
        }
    }

    /// Messages still to download across accounts that are downloading now.
    var downloadsRemaining: Int {
        statuses.values.filter(\.isDownloading).map { $0.total - $0.downloaded }.reduce(0, +)
    }

    /// Mailboxes (local ids) any download is working on right now.
    var busyMailboxIDs: Set<Int64> { statuses.values.reduce(into: Set<Int64>()) { $0.formUnion($1.busyMailboxes) } }

    /// Whether the account is syncing or downloading messages right now (shows a spinner).
    func isBusy(accountId: String) -> Bool {
        guard let s = statuses[accountId] else { return false }
        return s.phase == .syncing || s.isDownloading
    }

    /// "Downloaded X of Y messages" while an account isn't fully stored locally.
    func downloadInfo(accountId: String) -> String? {
        guard let s = statuses[accountId], s.total > 0, s.downloaded < s.total else { return nil }
        return "Downloaded \(s.downloaded.formatted()) of \(s.total.formatted()) messages"
    }

    /// Coalesces bursts of commits (e.g. during an initial sync) into at most ~3 UI refreshes per second.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            refreshScheduled = false
            myAddresses = (try? store.myAddresses()) ?? myAddresses
            dockCounters?.update()
            NotificationCenter.default.post(name: .mailStoreDidChange, object: nil)
        }
    }

    nonisolated private static func credentials(for account: AccountRecord) throws -> Credentials {
        #if DEBUG
            if account.id.hasPrefix("dev-") {
                return .basic(username: account.username, password: account.username.split(separator: "@")[0] + "-dev-pass")
            }
        #endif
        let secret = try Keychain.get(account: account.id)
        switch account.authKind {
        case .basic: return .basic(username: account.username, password: secret)
        case .bearer: return .bearer(token: secret)
        }
    }

    #if DEBUG
        /// Round-trips two secrets through the (Dev app's own) keychain item and logs the outcome.
        private func keychainSelfTest() {
            let log = Logger(subsystem: "app.mailmatej", category: "selftest")
            do {
                try Keychain.set("one", account: "selftest-1")
                try Keychain.set("two", account: "selftest-2")
                let ok = try Keychain.get(account: "selftest-1") == "one" && Keychain.get(account: "selftest-2") == "two"
                Keychain.delete(account: "selftest-1")
                Keychain.delete(account: "selftest-2")
                let gone = (try? Keychain.get(account: "selftest-1")) == nil
                log.notice("Keychain self-test: \(ok && gone ? "PASS" : "FAIL", privacy: .public)")
            } catch {
                log.error("Keychain self-test error: \(String(describing: error), privacy: .public)")
            }
        }

        /// `MMJ_DEV_ACCOUNTS=alice,bob,carol` adds the accounts created by dev/stalwart/seed.py,
        /// without touching the keychain (their passwords are derived from the name).
        private func addDevAccountsIfRequested() {
            guard let names = ProcessInfo.processInfo.environment["MMJ_DEV_ACCOUNTS"] else { return }
            for (i, name) in names.split(separator: ",").enumerated() {
                let record = AccountRecord(
                    id: "dev-\(name)", name: "\(name.capitalized) (local)",
                    sessionURL: "http://localhost:\(ProcessInfo.processInfo.environment["MMJ_DEV_PORT"] ?? "18080")/.well-known/jmap",
                    username: "\(name)@mmj.test",
                    authKind: .basic, sortOrder: 1000 + i)
                try? store.save(record)  // Upsert, so a changed dev server URL is picked up.
            }
        }
    #endif
}
