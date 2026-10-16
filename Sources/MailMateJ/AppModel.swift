import AppKit
import JMAPKit
import MailStore
import MailSync

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
        #if DEBUG
            addDevAccountsIfRequested()
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

    func fetchBody(messageId: Int64, accountId: String) async throws -> MessageBody {
        try await coordinator.fetchBody(messageId: messageId, accountId: accountId)
    }

    // MARK: Private

    private func statusChanged(_ status: AccountSyncStatus) {
        statuses[status.accountId] = status
        NotificationCenter.default.post(name: .syncStatusDidChange, object: nil)
    }

    /// Coalesces bursts of commits (e.g. during an initial sync) into at most ~3 UI refreshes per second.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            refreshScheduled = false
            myAddresses = (try? store.myAddresses()) ?? myAddresses
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
        /// `MMJ_DEV_ACCOUNTS=alice,bob,carol` adds the accounts created by dev/stalwart/seed.py,
        /// without touching the keychain (their passwords are derived from the name).
        private func addDevAccountsIfRequested() {
            guard let names = ProcessInfo.processInfo.environment["MMJ_DEV_ACCOUNTS"] else { return }
            let existing = Set(((try? store.accounts()) ?? []).map(\.id))
            for (i, name) in names.split(separator: ",").enumerated() where !existing.contains("dev-\(name)") {
                let record = AccountRecord(
                    id: "dev-\(name)", name: "\(name.capitalized) (local)",
                    sessionURL: "http://localhost:8080/.well-known/jmap", username: "\(name)@mmj.test",
                    authKind: .basic, sortOrder: 1000 + i)
                try? store.save(record)
            }
        }
    #endif
}
