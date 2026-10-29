import AppKit
import UniformTypeIdentifiers
import JMAPKit
import MailStore
import MailSync
import GmailKit
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
    var fullName = ""
    var emailAddresses = ""
}

/// App-wide state shared by windows: the store, the sync coordinator and sync statuses.
@MainActor
final class AppModel {
    static private(set) var shared: AppModel!

    let store: MailStore
    let coordinator: SyncCoordinator
    private(set) var statuses: [String: AccountSyncStatus] = [:]
    private(set) var myAddresses: Set<String> = []
    /// Addresses from stored mail, for completing address fields (loaded in the background).
    private(set) var knownAddresses: [MailStore.KnownAddress] = []
    private var knownAddressesLoaded: Date?

    /// Reloads `knownAddresses` in the background (at launch, after sending, and when a compose window
    /// opens with them over 10 minutes old).
    func refreshKnownAddresses(ifOlderThan age: TimeInterval = 0) {
        if let loaded = knownAddressesLoaded, Date().timeIntervalSince(loaded) < age { return }
        knownAddressesLoaded = Date()
        let store = self.store
        Task.detached(priority: .utility) {
            guard let known = try? store.knownAddresses() else { return }
            await MainActor.run { AppModel.shared?.knownAddresses = known }
        }
    }
    private var observation: StoreObservation?
    private var refreshScheduled = false
    /// When the UI last read the store: commits before it are shown already.
    private var refreshedAt = ContinuousClock.now
    /// The newest commit seen, for the refresh scheduled for it.
    private var latestCommit = ContinuousClock.now
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
            googleTokens: Self.googleTokens(for:),
            onStatus: { status in
                Task { @MainActor in AppModel.shared?.statusChanged(status) }
            },
            onArrived: { accountId, remoteIds in
                Task { @MainActor in AppModel.shared?.runRules(accountId: accountId, remoteIds: remoteIds) }
            },
            onQueuedChangeRefused: { _, error in
                Task { @MainActor in AppModel.shared?.reportRefusedQueuedChange(error) }
            })
    }

    func start() {
        observation = store.observeChanges {
            let committed = ContinuousClock.now  // called as the commit ends, before any refresh that follows it
            Task { @MainActor in AppModel.shared?.scheduleRefresh(committed: committed) }
        }
        myAddresses = (try? store.myAddresses()) ?? []
        refreshKnownAddresses()
        let store = self.store
        Task.detached(priority: .background) { _ = try? store.compactIfWorthwhile() }  // space deleted mail freed
        createDefaultSmartMailboxes()
        dockCounters = DockCounters(store: store)
        dockCounters?.update()
        #if DEBUG
            if let id = ProcessInfo.processInfo.environment["MMJ_DEBUG_FORGET_MAIL"] {
                // An account's messages and sync state gone, as before its first sync (for testing it).
                try? store.deleteMessages(accountId: id, remoteIds: Array((try? store.remoteIDs(accountId: id)) ?? []))
                for type in ["Email", "Mailbox", "GmailHistory", "GmailMapping", "GmailFullStart", "GmailRefetch", "GmailRefetchDone"] {
                    try? store.setSyncState(nil, accountId: id, type: type)
                }
            }
            addDevAccountsIfRequested()
            if ProcessInfo.processInfo.environment["MMJ_KEYCHAIN_SELFTEST"] != nil { keychainSelfTest() }
        #endif
        var pollInterval: Duration = .seconds(300)
        #if DEBUG
            if let seconds = Int(ProcessInfo.processInfo.environment["MMJ_DEBUG_POLL_SECONDS"] ?? "") { pollInterval = .seconds(seconds) }
        #endif
        Task { [pollInterval] in try? await coordinator.start(pollInterval: pollInterval) }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in AppModel.shared?.syncAll() }
        }
        // While the app is in use, Gmail accounts are checked every 10 s (see SyncCoordinator.setInUse).
        for (name, active) in [(NSApplication.didBecomeActiveNotification, true), (NSApplication.didResignActiveNotification, false)] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [coordinator] _ in
                Task { await coordinator.setInUse(active) }
            }
        }
        var active = NSApp.isActive
        #if DEBUG
            if ProcessInfo.processInfo.environment["MMJ_DEBUG_IN_USE"] != nil { active = true }  // tests run in the background
        #endif
        Task { [coordinator, active] in await coordinator.setInUse(active) }
    }

    func syncAll() {
        Task { await coordinator.syncAll() }
    }

    func sync(accountId: String) {
        Task { await coordinator.requestSync(accountId) }
    }

    var syncingCount: Int { statuses.values.filter { $0.phase == .syncing }.count }

    // MARK: Accounts

    @discardableResult
    func addAccount(_ draft: AccountDraft) async throws -> AccountRecord {
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
            fullName: draft.fullName, emailAddresses: draft.emailAddresses)
        try Keychain.set(draft.secret, account: record.id)
        try store.save(record)
        await coordinator.addAccount(record)
        return record
    }

    /// Makes sure the server has a sending identity for each address in the account's Email
    /// Address(es) (named with its Full Name). Returns the ones it refused and why.
    func ensureIdentities(accountId: String) async -> [(email: String, reason: String)] {
        guard let account = try? store.account(id: accountId), !account.addressList.isEmpty else {
            #if DEBUG
                NSLog("MMJ ensureIdentities: nothing listed for \(accountId)")
            #endif
            return []
        }
        do {
            let refused = try await coordinator.ensureIdentities(
                accountId: accountId, addresses: account.addressList, name: account.fullName)
            #if DEBUG
                NSLog("MMJ ensureIdentities \(account.addressList): refused \(refused)")
            #endif
            return refused
        } catch {
            return account.addressList.map { ($0, Self.describe(error)) }
        }
    }

    /// Saves edits to an account. If the server, user name, sign-in kind or password (`draft.secret`,
    /// empty to keep it) changed, they're checked against the server first, and the account reconnects
    /// with them; its messages stay. A server answering for a different account is refused.
    // MARK: Gmail

    /// The Google OAuth client baked into the app at build time (see scripts/bundle.sh); in debug
    /// builds MMJ_GOOGLE_OAUTH_JSON can point at the client file instead.
    nonisolated static var googleClient: GoogleClient? {
        #if DEBUG
            if let path = ProcessInfo.processInfo.environment["MMJ_GOOGLE_OAUTH_JSON"],
                let data = FileManager.default.contents(atPath: path)
            {
                return GoogleClient(json: data)
            }
        #endif
        guard let id = Bundle.main.object(forInfoDictionaryKey: "MMJGoogleClientID") as? String, !id.isEmpty else { return nil }
        let secret = Bundle.main.object(forInfoDictionaryKey: "MMJGoogleClientSecret") as? String
        return GoogleClient(id: id, secret: secret?.isEmpty == false ? secret : nil)
    }

    enum GmailError: LocalizedError {
        case noClient
        case alreadyAdded(String)
        case otherAccount(signedIn: String, expected: String)
        var errorDescription: String? {
            switch self {
            case .noClient:
                "This build has no Google sign-in set up. Put the OAuth client file from Google Cloud at "
                    + "google-oauth-client.json in the project and build again (see the README)."
            case .alreadyAdded(let email): "\(email) is already added."
            case .otherAccount(let signedIn, let expected):
                "You signed in to \(signedIn), not \(expected). Sign in again and choose \(expected)."
            }
        }
    }

    /// Google's sign-in in the browser (`loginHint` preselects the address): the account's tokens and
    /// its address.
    private func signInWithGoogle(loginHint: String?) async throws -> (tokens: GoogleOAuth.Tokens, email: String) {
        guard let client = Self.googleClient else { throw GmailError.noClient }
        #if DEBUG
            if ProcessInfo.processInfo.environment["MMJ_DEBUG_NO_BROWSER"] != nil {  // tests: no browser, as if cancelled
                NSLog("MMJ google sign-in: would open Google's sign-in for \(loginHint ?? "-")")
                throw GoogleOAuthError.cancelled
            }
        #endif
        let tokens = try await GoogleOAuth.authorize(client: client, loginHint: loginHint) { url in
            Task { @MainActor in NSWorkspace.shared.open(url) }
        }
        let source = GoogleTokenSource(
            client: client, refreshToken: tokens.refreshToken, accessToken: tokens.accessToken, expiry: tokens.expiry)
        return (tokens, try await GmailClient(tokens: source).profile().emailAddress.lowercased())
    }

    /// Adds a Gmail account: Google's sign-in opens in the browser (`loginHint` preselects the address),
    /// then the account is saved with its refresh token in the keychain and starts syncing.
    @discardableResult
    func addGmailAccount(_ draft: AccountDraft, loginHint: String?) async throws -> AccountRecord {
        let (tokens, email) = try await signInWithGoogle(loginHint: loginHint)
        if try store.accounts().contains(where: { $0.isGmail && $0.username == email }) { throw GmailError.alreadyAdded(email) }
        let record = AccountRecord(
            name: draft.name.isEmpty ? email : draft.name, kind: AccountRecord.gmailKind,
            sessionURL: "https://gmail.googleapis.com/gmail/v1/users/me", username: email, authKind: .bearer,
            remoteAccountId: email, fullName: draft.fullName,
            emailAddresses: draft.emailAddresses.isEmpty ? email : draft.emailAddresses)
        try Keychain.set(tokens.refreshToken, account: record.id)
        try store.save(record)
        refreshNow()
        await coordinator.addAccount(record)
        return record
    }

    /// Signs in to a Gmail account again (Take Online, for an account Google no longer takes the sign-in
    /// of; or to renew it): the new refresh token replaces the old one, and the account is back online
    /// with its mail as it is.
    func signInToGmailAgain(accountId: String) async throws {
        guard let account = try store.account(id: accountId), account.isGmail else { return }
        let (tokens, email) = try await signInWithGoogle(loginHint: account.username)
        guard email == account.username else { throw GmailError.otherAccount(signedIn: email, expected: account.username) }
        try Keychain.set(tokens.refreshToken, account: account.id)
        await coordinator.takeOnline(account)
    }

    /// Whether an account is offline (MailMate's Take Offline, or a Gmail account Google no longer takes
    /// the sign-in of), until Take Online.
    func isOffline(accountId: String) -> Bool { statuses[accountId]?.isOffline == true }

    /// Offline because Google no longer takes a Gmail account's sign-in: Take Online signs in again.
    func needsSignIn(accountId: String) -> Bool { statuses[accountId]?.needsSignIn == true }

    /// Take Offline: the account isn't synced (changes wait for it) until Take Online.
    func takeOffline(accountId: String) {
        Task { await coordinator.takeOffline(accountId) }
    }

    /// Take Online: the account syncs again. A Gmail account Google refused the sign-in of signs in
    /// first (Google's page in the browser), as does one whose sign-in Google dropped while it was
    /// offline: it goes straight there, as in MailMate, rather than online and offline again.
    func takeOnline(accountId: String) async throws {
        guard let account = try store.account(id: accountId) else { return }
        if needsSignIn(accountId: accountId), account.isGmail { return try await signInToGmailAgain(accountId: accountId) }
        if account.isGmail, await !Self.googleSignInWorks(account) { return try await signInToGmailAgain(accountId: accountId) }
        await coordinator.takeOnline(account)
    }

    /// Whether Google still takes a Gmail account's sign-in (gives it an access token); true when that
    /// can't be told (no connection, say), for its sync to find out.
    nonisolated private static func googleSignInWorks(_ account: AccountRecord) async -> Bool {
        do {
            _ = try await googleTokens(for: account).accessToken()
            return true
        } catch GoogleOAuthError.signInExpired {
            return false
        } catch {
            return true
        }
    }

    func updateAccount(_ old: AccountRecord, with draft: AccountDraft) async throws {
        if old.isGmail {  // Only the local details change: the sign-in stays.
            var record = old
            record.name = draft.name.isEmpty ? old.name : draft.name
            record.fullName = draft.fullName
            record.emailAddresses = draft.emailAddresses
            try store.save(record)
            return refreshNow()
        }
        var record = old
        record.name = draft.name.isEmpty ? old.name : draft.name
        record.fullName = draft.fullName
        record.emailAddresses = draft.emailAddresses
        record.sessionURL = draft.sessionURL.absoluteString
        record.authKind = draft.authKind
        if draft.authKind == .basic { record.username = draft.username }
        let reconnect = record.sessionURL != old.sessionURL || record.username != old.username
            || record.authKind != old.authKind || !draft.secret.isEmpty

        if reconnect {
            var secret = draft.secret
            if secret.isEmpty {  // Keep the saved one (or a Dev account's derived one).
                switch try Self.credentials(for: old) {
                case .basic(_, let password): secret = password
                case .bearer(let token): secret = token
                }
            }
            let credentials: Credentials =
                switch record.authKind {
                case .basic: .basic(username: record.username, password: secret)
                case .bearer: .bearer(token: secret)
                }
            let session = try await JMAPClient(sessionURL: draft.sessionURL, credentials: credentials).fetchSession()
            guard let mailAccountId = session.primaryMailAccountId else { throw JMAPError.missingCapability(Capability.mail) }
            if let known = old.remoteAccountId, known != mailAccountId { throw AccountEditError.differentAccount }
            if record.authKind == .bearer { record.username = session.username }
            record.remoteAccountId = mailAccountId
            if !draft.secret.isEmpty { try Keychain.set(draft.secret, account: record.id) }
        }
        try store.save(record)
        if reconnect {
            await coordinator.removeAccount(id: record.id)
            statuses.removeValue(forKey: record.id)
            await coordinator.addAccount(record)
        }
    }

    /// Rename Source…: the account's name in the sidebar, kept here (the server isn't told).
    func renameAccount(id: String, to name: String) {
        guard var record = try? store.account(id: id) else { return }
        record.name = name
        try? store.save(record)
        refreshNow()
    }

    enum AccountEditError: LocalizedError {
        case differentAccount
        var errorDescription: String? {
            "Those details sign in to a different account on the server. Add it as a new account instead."
        }
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

    /// The sidebar warning for an account that failed to sync, if any, with the changes waiting for it.
    /// An offline account has none: its row is greyed out instead (see `offlineReason`).
    func syncWarning(accountId: String) -> String? {
        isOffline(accountId: accountId) ? nil : statusMessage(accountId)
    }

    /// For an offline account's row: why it's offline (Google wants it signed in to again), and the
    /// changes waiting for it; nil while it's online, or offline with nothing to say.
    func offlineReason(accountId: String) -> String? {
        isOffline(accountId: accountId) ? statusMessage(accountId) : nil
    }

    private func statusMessage(_ accountId: String) -> String? {
        guard let status = statuses[accountId] else { return nil }
        var parts: [String] = []
        // Why the last sync failed; while offline, only when that's why (Google wants a sign-in).
        if case .failed(let text) = status.phase, !status.isOffline || status.needsSignIn { parts.append(text) }
        if status.queuedChanges > 0, !parts.isEmpty || status.isOffline {
            let changes = status.queuedChanges == 1 ? "1 change" : "\(status.queuedChanges) changes"
            parts.append(status.isOffline
                ? "\(changes) will be made on the server once it’s online."
                : "\(changes) will be made on the server once it can be reached.")
        }
        guard !parts.isEmpty else { return nil }
        #if DEBUG
            if let detail = status.errorDetail { parts.append(detail) }
        #endif
        return parts.joined(separator: "\n\n")
    }

    /// A change made while offline that the server refused once reachable; its messages show the
    /// server's state again.
    func reportRefusedQueuedChange(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "A change made while offline couldn’t be made on the server."
        alert.informativeText = Self.describe(error) + "\n\nThe messages show the server’s state again."
        present(alert)
    }

    // MARK: Message actions

    enum MessageAction {
        case archive, junk, delete, markRead, markUnread, flag, unflag
        /// Move Out of Junk: into the Inbox, no longer marked as junk.
        case notJunk
        /// A rule's Set/Remove Tag/Keyword.
        case keyword(String, Bool)
        /// A rule's Copy to Mailbox (same account: the message is in that mailbox too).
        case copy(toMailboxId: Int64)
        /// A rule's Delete Permanently.
        case deletePermanently
        /// Into one mailbox of the messages' account.
        case move(toMailboxId: Int64)
        /// Out of this mailbox only, for messages that are in others too (a message stays in at least one).
        case removeFromMailbox(Int64)
        /// Into each message's account's mailbox with this role (a Unified mailbox, such as Sent Messages).
        case moveToRole(String)
        /// Each message back into the mailboxes it was in (undo of a move), and back to junk (true) or
        /// not junk (false) when the move had changed that.
        case restoreMailboxes([Int64: [Int64]], junk: Bool?)
    }

    /// Archives, marks as junk, deletes, marks or flags messages: here at once, then on the server.
    /// The local change is made before this returns and the lists refresh right away (no debounce), so
    /// the app reacts instantly, as MailMate does; the server requests follow in the background.
    /// Messages of several accounts are handled per account. Delete moves to Deleted Messages; messages
    /// already there are deleted for good (after `confirmPermanentDelete` agrees).
    func perform(_ action: MessageAction, on ids: [Int64], confirmPermanentDelete: @escaping (Int) async -> Bool) {
        guard let refs = try? store.refs(ids: ids), !refs.isEmpty else { return }
        var work: [(accountId: String, refs: [MailStore.MessageRef], server: ServerWork)] = []
        for (accountId, refs) in Dictionary(grouping: refs, by: \.accountId) {
            do {
                work.append((accountId, refs, try applyLocally(action, accountId: accountId, refs: refs)))
            } catch {
                report(error, count: refs.count)
            }
        }
        refreshNow()
        inBackground { [self] in
            for item in work {
                do {
                    try await send(item.server, accountId: item.accountId, refs: item.refs, confirm: confirmPermanentDelete)
                } catch {
                    report(error, count: item.refs.count)
                }
            }
        }
    }

    /// Marks every message a mailbox shows as read: here at once, then on the servers.
    func markAllRead(_ scope: MessageScope) {
        guard let ids = try? store.unreadIDs(scope: scope), !ids.isEmpty else { return }
        perform(.markRead, on: ids) { _ in false }
    }

    /// Erases every message a mailbox shows (Empty "Deleted Messages"): gone here at once, then deleted
    /// for good on the servers.
    func emptyMailbox(_ scope: MessageScope) {
        guard let ids = try? store.messageIDs(scope: scope), !ids.isEmpty else { return }
        perform(.deletePermanently, on: ids) { _ in true }  // asked before
    }

    /// What's left for the server once the local change is made.
    private struct ServerWork {
        var updates: [(remoteIds: [String], patch: [String: JSONValue])] = []
        /// The account has no Archive yet: create it, then move there (here and on the server).
        var archiveIntoNewMailbox = false
        /// Where those messages were, to put them back if the Archive can't be made.
        var previousMailboxes: [Int64: [Int64]] = [:]
        /// Messages already in Deleted Messages, deleted for good once confirmed.
        var deleteForGood: [MailStore.MessageRef] = []
    }

    private func applyLocally(_ action: MessageAction, accountId: String, refs: [MailStore.MessageRef]) throws -> ServerWork {
        let ids = refs.map(\.id), remoteIds = refs.map(\.remoteId)
        var work = ServerWork()
        func setKeyword(_ keyword: String, _ on: Bool) throws {
            try store.setKeyword(keyword, on, messageIds: ids)
            work.updates.append((remoteIds, ["keywords/\(keyword)": on ? .bool(true) : .null]))
        }
        func move(_ messages: [MailStore.MessageRef], to target: MailboxRecord, extra: [String: JSONValue] = [:]) throws {
            try store.moveMessages(messages.map(\.id), toMailboxId: target.id)
            var patch = extra
            patch["mailboxIds"] = .object([target.remoteId: .bool(true)])
            work.updates.append((messages.map(\.remoteId), patch))
        }
        switch action {
        case .markRead: try setKeyword("$seen", true)
        case .markUnread: try setKeyword("$seen", false)
        case .flag: try setKeyword("$flagged", true)
        case .unflag: try setKeyword("$flagged", false)
        case .keyword(let keyword, let on): try setKeyword(keyword, on)
        case .copy(let mailboxId):
            guard let target = try store.mailboxes().first(where: { $0.id == mailboxId && $0.accountId == accountId }) else {
                throw MessageActionError.noMailbox(role: "")
            }
            let current = try store.mailboxIDs(messageIds: ids)
            try store.setMailboxes(Dictionary(
                ids.filter { !(current[$0] ?? []).contains(target.id) }.map { ($0, (current[$0] ?? []) + [target.id]) },
                uniquingKeysWith: { a, _ in a }))
            work.updates.append((remoteIds, ["mailboxIds/\(target.remoteId)": .bool(true)]))
        case .deletePermanently:
            try store.deleteMessages(accountId: accountId, remoteIds: remoteIds)  // gone here at once
            work.deleteForGood = refs
        case .archive:
            if let archive = try store.mailbox(accountId: accountId, role: "archive") {
                try move(refs, to: archive)
            } else {
                // An account without an Archive gets one, as other mail apps do. Until the server has made it,
                // the messages are out of their mailboxes here, so they leave the lists at once.
                work.archiveIntoNewMailbox = true
                work.previousMailboxes = try store.mailboxIDs(messageIds: ids)
                try store.setMailboxes(Dictionary(ids.map { ($0, []) }, uniquingKeysWith: { a, _ in a }))
            }
        case .junk:
            guard let junk = try store.mailbox(accountId: accountId, role: "junk") else {
                throw MessageActionError.noMailbox(role: "junk")
            }
            try move(refs, to: junk, extra: ["keywords/$junk": .bool(true), "keywords/$notjunk": .null])
        case .notJunk:
            guard let inbox = try store.mailbox(accountId: accountId, role: "inbox") else {
                throw MessageActionError.noMailbox(role: "inbox")
            }
            try move(refs, to: inbox, extra: ["keywords/$junk": .null, "keywords/$notjunk": .bool(true)])
        case .removeFromMailbox(let mailboxId):
            guard let target = try store.mailboxes().first(where: { $0.id == mailboxId && $0.accountId == accountId }) else {
                return work
            }
            let current = try store.mailboxIDs(messageIds: ids)
            let removable = refs.filter { ref in
                let boxes = current[ref.id] ?? []
                return boxes.contains(mailboxId) && boxes.count > 1
            }
            try store.setMailboxes(Dictionary(
                removable.map { ($0.id, (current[$0.id] ?? []).filter { $0 != mailboxId }) }, uniquingKeysWith: { a, _ in a }))
            if !removable.isEmpty { work.updates.append((removable.map(\.remoteId), ["mailboxIds/\(target.remoteId)": .null])) }
        case .move(let mailboxId):
            guard let target = try store.mailboxes().first(where: { $0.id == mailboxId && $0.accountId == accountId }) else {
                throw MessageActionError.noMailbox(role: "")
            }
            try move(refs, to: target)
        case .moveToRole(let role):
            guard let target = try store.mailbox(accountId: accountId, role: role) else {
                throw MessageActionError.noMailbox(role: role)
            }
            try move(refs, to: target)
        case .restoreMailboxes(let saved, let junk):
            let remote = Dictionary(uniqueKeysWithValues: try store.mailboxes().map { ($0.id, $0.remoteId) })
            // One request per set of mailboxes (usually all the same).
            for (boxes, group) in Dictionary(grouping: refs, by: { Set(saved[$0.id] ?? []) }) where !boxes.isEmpty {
                try store.setMailboxes(Dictionary(group.map { ($0.id, Array(boxes)) }, uniquingKeysWith: { a, _ in a }))
                var patch: [String: JSONValue] = [
                    "mailboxIds": .object(Dictionary(uniqueKeysWithValues: boxes.compactMap { remote[$0] }.map { ($0, JSONValue.bool(true)) }))
                ]
                if let junk {
                    patch["keywords/$junk"] = junk ? .bool(true) : .null
                    patch["keywords/$notjunk"] = junk ? .null : .bool(true)
                }
                work.updates.append((group.map(\.remoteId), patch))
            }
        case .delete:
            let inTrash = try store.messageIDs(ids, inRole: "trash")
            let toTrash = refs.filter { !inTrash.contains($0.id) }
            if !toTrash.isEmpty {
                guard let trash = try store.mailbox(accountId: accountId, role: "trash") else {
                    throw MessageActionError.noMailbox(role: "trash")
                }
                try move(toTrash, to: trash)
            }
            work.deleteForGood = refs.filter { inTrash.contains($0.id) }
        }
        return work
    }

    private func send(
        _ work: ServerWork, accountId: String, refs: [MailStore.MessageRef], confirm: (Int) async -> Bool
    ) async throws {
        var updates = work.updates
        if work.archiveIntoNewMailbox {
            let archive: MailboxRecord
            do {
                try await coordinator.createMailbox(accountId: accountId, name: "Archive", role: "archive")
                guard let made = try store.mailbox(accountId: accountId, role: "archive") else {
                    throw MessageActionError.noMailbox(role: "archive")
                }
                archive = made
            } catch {
                try? store.setMailboxes(work.previousMailboxes)  // back
                refreshNow()
                throw error
            }
            try store.moveMessages(refs.map(\.id), toMailboxId: archive.id)
            refreshNow()
            updates.append((refs.map(\.remoteId), ["mailboxIds": .object([archive.remoteId: .bool(true)])]))
        }
        for update in updates {
            try await coordinator.update(accountId: accountId, remoteIds: update.remoteIds, patch: update.patch)
        }
        if !work.deleteForGood.isEmpty, await confirm(work.deleteForGood.count) {
            try await coordinator.destroy(accountId: accountId, remoteIds: work.deleteForGood.map(\.remoteId))
        }
    }

    private func report(_ error: Error, count: Int) {
        Logger(subsystem: "app.mailmatej", category: "changes")
            .error("Couldn't change \(count) messages: \(String(describing: error), privacy: .public)")
        let alert = NSAlert()
        alert.messageText = "Couldn’t change \(count == 1 ? "the message" : "\(count) messages") on the server."
        alert.informativeText = Self.describe(error)
        present(alert)
    }

    /// Shows an error as a sheet on the main window, so the lists can still update behind it (a modal
    /// alert would hold them until it's dismissed).
    private func present(_ alert: NSAlert) {
        if let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    private func present(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t save the smart mailbox."
        alert.informativeText = Self.describe(error)
        present(alert)
    }

    /// Refreshes the UI from the store now, skipping the debounce meant for sync bursts. With
    /// `countsUnchanged` only the mailbox list changed (a new smart mailbox: its messages are counted
    /// already, in its parent's), so the sidebar keeps its counts and the Dock its badges.
    func refreshNow(countsUnchanged: Bool = false) {
        refreshedAt = .now
        if !countsUnchanged {
            myAddresses = (try? store.myAddresses()) ?? myAddresses
            dockCounters?.update()
        }
        NotificationCenter.default.post(
            name: .mailStoreDidChange, object: nil,
            userInfo: countsUnchanged ? [Self.countsUnchangedKey: true] : [Self.madeHereKey: true])
    }

    /// In a store change's userInfo: see `refreshNow(countsUnchanged:)`.
    nonisolated static let countsUnchangedKey = "countsUnchanged"
    /// In a store change's userInfo: a change made here (an action, a mailbox made or moved), which
    /// shows at once; not one a sync brought.
    nonisolated static let madeHereKey = "madeHere"

    // MARK: Work in progress

    /// Changes under way on servers (message actions, moves, sends). Quitting waits for them, as MailMate
    /// does (see QuitProgress), so none is cut off half done.
    private(set) var pendingWork = 0 {
        didSet {
            onPendingWorkChange?(pendingWork)
            if pendingWork == 0 {
                let waiting = whenIdle
                whenIdle = []
                waiting.forEach { $0() }
            }
        }
    }
    var onPendingWorkChange: ((Int) -> Void)?
    private var whenIdle: [() -> Void] = []

    /// Runs server work in the background, counted in `pendingWork`.
    func inBackground(_ work: @escaping @MainActor () async -> Void) {
        pendingWork += 1
        Task {
            #if DEBUG
                if let seconds = Double(ProcessInfo.processInfo.environment["MMJ_DEBUG_SLOW_WORK"] ?? "") {
                    try? await Task.sleep(for: .seconds(seconds))  // a slow server, to test quitting meanwhile
                }
            #endif
            await work()
            pendingWork -= 1
        }
    }

    /// Calls `done` once no server work is under way (at once if none is).
    func whenNoPendingWork(_ done: @escaping () -> Void) {
        if pendingWork == 0 { done() } else { whenIdle.append(done) }
    }

    // MARK: Rules

    /// Runs the rules on newly arrived messages, as MailMate does: each rule of a mailbox the messages
    /// are in, in order, on those meeting its conditions (see `runRule`). A message one rule moves
    /// isn't touched by later rules.
    func runRules(accountId: String, remoteIds: [String]) {
        guard let rules = try? store.rules(), rules.contains(where: \.definition.enabled),
            let ids = try? store.messageIDs(accountId: accountId, remoteIds: remoteIds), !ids.isEmpty
        else { return }
        run(rules, on: ids)
    }

    /// Mailbox › Apply Rules of “…”, as MailMate's: a mailbox's own rules on messages of the list shown
    /// (its own, or another's: “to Current List”), as if they had just arrived, so on those meeting the
    /// conditions wherever they are. Returns how many of `ids` some rule matched.
    @discardableResult
    func applyRules(mailboxKey: String, to ids: [Int64]) -> Int {
        guard let rules = try? store.rules(mailboxKey: mailboxKey), !ids.isEmpty else { return 0 }
        return run(rules, on: ids, anywhere: true)
    }

    /// Whether the mailbox has a rule to apply.
    func hasRules(mailboxKey: String) -> Bool {
        ((try? store.rules(mailboxKey: mailboxKey)) ?? []).contains { $0.parentId == nil && $0.definition.enabled }
    }

    /// Each top-level rule of `rules`, in order, on those of `ids` an earlier one didn't move away.
    @discardableResult
    private func run(_ rules: [RuleRecord], on ids: [Int64], anywhere: Bool = false) -> Int {
        var remaining = Set(ids), matched = Set<Int64>()
        for rule in rules where rule.parentId == nil && rule.definition.enabled && !remaining.isEmpty {
            let result = runRule(rule, on: Array(remaining), all: rules, anywhere: anywhere)
            remaining.subtract(result.moved)
            matched.formUnion(result.matched)
            #if DEBUG
                NSLog("MMJ rules: \(rule.definition.name) matched \(result.matched.count) of \(ids.count)")
            #endif
        }
        return matched.count
    }

    /// Runs one rule on those of `ids` its mailbox and conditions take: its tags and copies at once, then
    /// its subrules on the messages it matched (MailMate's subrules), then — after any Redirect or Forward
    /// has been sent, since they read the message — its first move or delete on what the subrules didn't
    /// move. Returns what it matched and what it (or a subrule) moved away. With `anywhere`, the rule's
    /// mailbox doesn't narrow the messages (Apply Rules).
    @discardableResult
    func runRule(_ rule: RuleRecord, on ids: [Int64], all: [RuleRecord]? = nil, anywhere: Bool = false)
        -> (matched: [Int64], moved: Set<Int64>)
    {
        guard let matched = try? store.messages(ids, matching: rule, anywhere: anywhere), !matched.isEmpty else { return ([], []) }
        let actions = rule.definition.actions.filter(\.enabled)
        let sends = actions.filter { $0.kind == .redirect || $0.kind == .forward }
        for action in actions where !action.kind.moves && !sends.contains(action) { apply(action, to: matched) }
        var moved = Set<Int64>()
        let rules = all ?? ((try? store.rules()) ?? [])
        for child in rules where child.parentId == rule.id && child.definition.enabled {
            moved.formUnion(runRule(child, on: matched.filter { !moved.contains($0) }, all: rules, anywhere: anywhere).moved)
        }
        let rest = matched.filter { !moved.contains($0) }
        if let move = actions.first(where: \.kind.moves), !rest.isEmpty {
            if sends.isEmpty {
                apply(move, to: rest)
            } else {
                inBackground { [self] in
                    for action in sends { await send(action, messages: matched) }
                    apply(move, to: rest)
                }
            }
            moved.formUnion(rest)
        } else if !sends.isEmpty {
            inBackground { [self] in for action in sends { await send(action, messages: matched) } }
        }
        return (matched, moved)
    }

    private func apply(_ action: RuleAction, to ids: [Int64]) {
        let never: (Int) async -> Bool = { _ in false }  // only Delete Permanently deletes for good
        switch action.kind {
        case .setKeyword, .removeKeyword:
            guard !action.value.isEmpty else { return }
            perform(.keyword(action.value, action.kind == .setKeyword), on: ids, confirmPermanentDelete: never)
        case .delete: perform(.delete, on: ids, confirmPermanentDelete: never)
        case .deletePermanently: perform(.deletePermanently, on: ids, confirmPermanentDelete: { _ in true })
        case .archive: perform(.archive, on: ids, confirmPermanentDelete: never)
        case .junk: perform(.junk, on: ids, confirmPermanentDelete: never)
        case .move, .copy:
            // A unified mailbox: each message's own (its account's Archive, Inbox, ...).
            if case .role(let role)? = MessageScope(key: action.value) {
                if action.kind == .move {
                    // Archive as the toolbar does it (an account without one gets one); other roles as they are.
                    return perform(role == "archive" ? .archive : .moveToRole(role), on: ids, confirmPermanentDelete: never)
                }
                guard let refs = try? store.refs(ids: ids) else { return }
                for (accountId, group) in Dictionary(grouping: refs, by: \.accountId) {
                    if let target = try? store.mailbox(accountId: accountId, role: role) {
                        perform(.copy(toMailboxId: target.id), on: group.map(\.id), confirmPermanentDelete: never)
                    }
                }
                return
            }
            guard let mailboxId = Int64(action.value), let target = try? store.mailboxes().first(where: { $0.id == mailboxId }),
                let refs = try? store.refs(ids: ids)
            else { return }
            let same = refs.filter { $0.accountId == target.accountId }, other = refs.filter { $0.accountId != target.accountId }
            let local: MessageAction = action.kind == .move ? .move(toMailboxId: mailboxId) : .copy(toMailboxId: mailboxId)
            if !same.isEmpty { perform(local, on: same.map(\.id), confirmPermanentDelete: never) }
            if !other.isEmpty {
                if action.kind == .move { moveAcrossAccounts(other, toMailboxId: mailboxId) } else { copyAcrossAccounts(other, toMailboxId: mailboxId) }
            }
        case .redirect, .forward: break  // sent by `runRule`
        }
    }

    /// Redirect (the message as it is) or Forward (a new message quoting it) to the action's address,
    /// from an identity of the message's account. Failures are reported.
    private func send(_ action: RuleAction, messages ids: [Int64]) async {
        let address = action.value.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { return }
        for id in ids {
            do {
                guard let detail = try store.detail(id: id) else { continue }
                if action.kind == .redirect {
                    guard let identity = try store.identities().first(where: { $0.accountId == detail.accountId }) else {
                        throw ComposeError.noIdentities
                    }
                    try await coordinator.redirect(
                        accountId: detail.accountId, remoteId: detail.remoteId, to: [address], identityId: identity.remoteId,
                        mailFrom: identity.envelopeEmail ?? identity.email)
                } else {
                    let setup = try await composeSetup(.forward, messageId: id)
                    guard let identity = setup.identity else { throw ComposeError.noIdentities }
                    var message = OutgoingMessage(
                        identityId: identity.remoteId, from: EmailAddress(name: identity.name, email: identity.email),
                        to: [EmailAddress(name: nil, email: address)], cc: [], bcc: [], subject: setup.draft.subject,
                        text: setup.draft.text, attachments: setup.attachments)
                    message.mailFrom = identity.envelopeEmail
                    try await coordinator.send(accountId: identity.accountId, message)
                    perform(.keyword("$forwarded", true), on: [id]) { _ in false }
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "A rule couldn’t \(action.kind == .redirect ? "redirect" : "forward") a message to \(address)."
                alert.informativeText = Self.describe(error)
                present(alert)
            }
        }
    }

    /// Copies messages into a mailbox of another account (a rule's Copy to Mailbox), keeping the originals.
    func copyAcrossAccounts(_ refs: [MailStore.MessageRef], toMailboxId mailboxId: Int64) {
        guard let target = try? store.mailboxes().first(where: { $0.id == mailboxId }) else { return }
        inBackground { [self] in
            for ref in refs {
                do {
                    guard let detail = try store.detail(id: ref.id) else { continue }
                    var raw = store.blobs.read(accountId: ref.accountId, blobId: detail.blobId)
                    if raw == nil {
                        raw = try await coordinator.downloadBlob(
                            accountId: ref.accountId, blobId: detail.blobId, type: "message/rfc822", name: "message.eml")
                    }
                    guard let raw else { continue }
                    try await coordinator.importMessage(
                        accountId: target.accountId, raw, mailboxRemoteId: target.remoteId,
                        keywords: (try? store.keywords(messageId: ref.id)) ?? [], receivedAt: detail.receivedAt)
                } catch {
                    report(error, count: 1)
                }
            }
        }
    }

    /// Renames a folder: here at once, then on the server; if the server refuses, the old name comes back.
    func renameMailbox(id: Int64, to name: String) {
        guard let box = try? store.mailboxes().first(where: { $0.id == id }), box.name != name else { return }
        try? store.renameMailbox(id: id, to: name)
        refreshNow()
        Task {
            do {
                try await coordinator.renameMailbox(accountId: box.accountId, remoteId: box.remoteId, to: name)
            } catch {
                try? store.renameMailbox(id: id, to: box.name)
                refreshNow()
                let alert = NSAlert()
                alert.messageText = "Couldn’t rename “\(box.name)”."
                alert.informativeText = Self.describe(error)
                present(alert)
            }
        }
    }

    // MARK: Smart mailboxes

    /// Narrows a special mailbox (Inbox, All Messages, ...) by its Conditions tab.
    func setSpecialCondition(_ condition: SmartCondition, key: String) {
        do {
            try store.setSpecialCondition(condition, key: key)
            refreshNow()
        } catch {
            present(error)
        }
    }

    private static let flaggedDefaultsKey = "FlaggedSmartMailboxID"

    /// The Flagged smart mailbox MailMateJ offers by default, if it still exists.
    var flaggedSmartMailboxID: Int64? {
        let id = Int64(UserDefaults.standard.integer(forKey: Self.flaggedDefaultsKey))
        return id != 0 && (try? store.smartMailboxes())?.contains(where: { $0.id == id }) == true ? id : nil
    }

    /// As MailMate: Flagged is an ordinary smart mailbox ("Message is Flagged"), made once, first among
    /// the smart mailboxes; deleting or editing it sticks. It keeps the Flagged mailbox's submailboxes
    /// (by account, by source), and a Dock counter that counted Flagged counts it.
    private func createDefaultSmartMailboxes() {
        guard UserDefaults.standard.object(forKey: Self.flaggedDefaultsKey) == nil else { return }
        let old = SubmailboxSettings.settings(for: "unified.flagged")
        var definition = SmartDefinition(
            sources: SmartSources(scopes: [MessageScope.allMessages.key]),
            condition: .compound(.all, [.rule(.status, .is, SmartStatus.flagged.rawValue)]),
            icon: "flag")
        definition.split.byAccount = old.splitsByAccount
        if old.splitsBySource {
            definition.split.byValue = true
            definition.split.field = .mailbox
        }
        definition.split.unlessOnlyOne = old.unlessOnlyOne
        guard let id = try? store.createSmartMailbox(name: "Flagged", parentId: nil) else { return }
        MailboxSettings.forgetSmartMailbox(id)
        try? store.updateSmartMailbox(id: id, definition: definition)
        try? store.moveSmartMailboxFirst(id: id)
        UserDefaults.standard.set(Int(id), forKey: Self.flaggedDefaultsKey)
        let settings = CounterSettings.shared
        for (corner, config) in settings.counters where config.source == MessageScope.flagged.key {
            settings.counters[corner]?.source = MessageScope.smart(id).key
        }
    }

    /// Creates a smart mailbox (inside `parentId`, if given) and shows it at once.
    func createSmartMailbox(name: String, parentId: Int64?, parentKey: String? = nil, sources: [String]? = nil) -> Int64? {
        do {
            let id = try store.createSmartMailbox(name: name, parentId: parentId, parentKey: parentKey, sources: sources)
            MailboxSettings.forgetSmartMailbox(id)  // one deleted earlier may have had its id
            refreshNow(countsUnchanged: true)
            return id
        } catch {
            present(error)
            return nil
        }
    }

    func updateSmartMailbox(id: Int64, name: String? = nil, definition: SmartDefinition? = nil) {
        do {
            try store.updateSmartMailbox(id: id, name: name, definition: definition)
            refreshNow()
        } catch {
            present(error)
        }
    }

    func deleteSmartMailbox(id: Int64) {
        do {
            // The smart mailboxes inside it go too, and so do their settings.
            let all = try store.smartMailboxes()
            var gone = [id]
            var next = 0
            while next < gone.count {
                gone += all.filter { $0.parentId == gone[next] }.map(\.id)
                next += 1
            }
            try store.deleteSmartMailbox(id: id)
            gone.forEach(MailboxSettings.forgetSmartMailbox)
            refreshNow()
        } catch {
            present(error)
        }
    }

    enum MessageActionError: LocalizedError {
        case noMailbox(role: String)

        var errorDescription: String? {
            switch self {
            case .noMailbox(let role):
                let name = ["archive": "Archive", "junk": "Junk", "trash": "Deleted Messages"][role] ?? "matching"
                return "This account has no \(name) mailbox."
            }
        }
    }

    /// Moves messages into a mailbox of another account, as MailMate does, and as instantly: they leave
    /// the lists at once, then in the background each is copied whole (raw message, keywords, date) into
    /// the mailbox, and only once that account has confirmed the copy is the original deleted for good.
    /// A message that fails to copy comes back where it was.
    func moveAcrossAccounts(_ refs: [MailStore.MessageRef], toMailboxId mailboxId: Int64) {
        guard let target = try? store.mailboxes().first(where: { $0.id == mailboxId }) else { return }
        struct Pending { var ref: MailStore.MessageRef; var blobId: String; var keywords: [String]; var receivedAt: Date }
        let pending: [Pending] = refs.compactMap { ref in
            guard let detail = try? store.detail(id: ref.id) else { return nil }
            return Pending(
                ref: ref, blobId: detail.blobId, keywords: (try? store.keywords(messageId: ref.id)) ?? [],
                receivedAt: detail.receivedAt)
        }
        // Out of the lists now; the server catches up.
        for (accountId, group) in Dictionary(grouping: pending, by: \.ref.accountId) {
            try? store.deleteMessages(accountId: accountId, remoteIds: group.map(\.ref.remoteId))
        }
        refreshNow()
        inBackground { [self] in
            var failed: [(Pending, Error)] = []
            for item in pending {
                do {
                    // The move works from the raw message on disk (usually there), so it can wait in the
                    // queue while a server can't be reached.
                    if !store.blobs.contains(accountId: item.ref.accountId, blobId: item.blobId) {
                        let raw = try await coordinator.downloadBlob(
                            accountId: item.ref.accountId, blobId: item.blobId, type: "message/rfc822", name: "message.eml")
                        try store.blobs.write(raw, accountId: item.ref.accountId, blobId: item.blobId)
                    }
                    #if DEBUG
                        if ProcessInfo.processInfo.environment["MMJ_DEBUG_FAIL_IMPORT"] != nil {
                            throw MessageActionError.noMailbox(role: "")  // To test the way back.
                        }
                    #endif
                    try await coordinator.moveAcross(
                        accountId: item.ref.accountId, remoteId: item.ref.remoteId, blobId: item.blobId,
                        toAccount: target.accountId, mailboxRemoteId: target.remoteId, keywords: item.keywords,
                        receivedAt: item.receivedAt)
                } catch {
                    failed.append((item, error))
                }
            }
            guard let (_, error) = failed.first else { return }
            for (accountId, group) in Dictionary(grouping: failed.map(\.0), by: \.ref.accountId) {
                try? await coordinator.restore(accountId: accountId, remoteIds: group.map(\.ref.remoteId))
            }
            refreshNow()
            let alert = NSAlert()
            alert.messageText = "Couldn’t move \(failed.count == 1 ? "a message" : "\(failed.count) messages") to the other account."
            alert.informativeText = Self.describe(error) + (failed.count == 1
                ? "\n\nIt’s back where it was." : "\n\nThey’re back where they were.")
            present(alert)
        }
    }

    /// Creates a mailbox inside `parentId` (in its account) and returns it once synced.
    func createSubmailbox(named name: String, inside parentId: Int64) async throws -> MailboxRecord {
        guard let parent = try store.mailboxes().first(where: { $0.id == parentId }) else {
            throw MessageActionError.noMailbox(role: "")
        }
        try await coordinator.createMailbox(accountId: parent.accountId, name: name, role: nil, parentRemoteId: parent.remoteId)
        guard let created = try store.mailboxes().first(where: {
            $0.accountId == parent.accountId && $0.parentRemoteId == parent.remoteId && $0.name == name
        }) else { throw MessageActionError.noMailbox(role: "") }
        refreshNow()
        return created
    }

    /// Creates a mailbox inside `parentId` (in its account), then moves the messages there.
    func moveToNewMailbox(named name: String, inside parentId: Int64, messages ids: [Int64], then perform: @escaping (MessageAction) -> Void) {
        guard let parent = try? store.mailboxes().first(where: { $0.id == parentId }) else { return }
        inBackground { [self] in
            do {
                try await coordinator.createMailbox(accountId: parent.accountId, name: name, role: nil, parentRemoteId: parent.remoteId)
                guard let created = try store.mailboxes().first(where: {
                    $0.accountId == parent.accountId && $0.parentRemoteId == parent.remoteId && $0.name == name
                }) else { throw MessageActionError.noMailbox(role: "") }
                refreshNow()
                perform(.move(toMailboxId: created.id))
            } catch {
                report(error, count: ids.count)
            }
        }
    }

    // MARK: Composing

    /// Whether any account can send (its identities are known).
    var canCompose: Bool { !((try? store.identities()) ?? []).isEmpty }

    /// Opens a compose window: a new message (from the account of `messageId`, if given), or a reply to
    /// or forward of `messageId`, quoting its text (downloaded first if it isn't stored yet).
    func compose(_ kind: ComposeKind, messageId: Int64?, window: NSWindow?) {
        Task {
            do {
                ComposeWindowController.show(model: self, setup: try await composeSetup(kind, messageId: messageId))
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn’t start the message."
                alert.informativeText = Self.describe(error)
                if let window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
            }
        }
    }

    private func composeSetup(_ kind: ComposeKind, messageId: Int64?) async throws -> ComposeWindowController.Setup {
        let identities = try store.identities()
        guard !identities.isEmpty else { throw ComposeError.noIdentities }
        let detail = try messageId.flatMap { try store.detail(id: $0) }
        guard kind != .new else {
            let identity = identities.first { $0.accountId == detail?.accountId } ?? identities.first
            return ComposeWindowController.Setup(identities: identities, identity: identity)
        }
        guard let messageId, let detail else { throw CocoaError(.fileNoSuchFile) }

        var body = try store.body(messageId: messageId)
        if body == nil { body = try await fetchBody(messageId: messageId, accountId: detail.accountId) }
        var text = body?.text ?? ""
        if text.isEmpty, let html = body?.html { text = Compose.plainText(fromHTML: html) }
        let original = Compose.Original(detail, text: text)

        var setup = ComposeWindowController.Setup(
            identities: identities,
            identity: Compose.identity(replyingTo: original, accountId: detail.accountId, identities: identities),
            draft: Compose.draft(
                kind, original: original, myAddresses: myAddresses,
                accountAddresses: Set(identities.filter { $0.accountId == detail.accountId }.map(\.email))))
        if kind == .forward {
            setup.attachments = MessageViewController.attachments(messageId: messageId, html: body?.html, store: store)
            setup.attachmentsAccountId = detail.accountId
            setup.original = (messageId, "$forwarded")
        } else {
            (setup.inReplyTo, setup.references) = try await replyHeaders(messageId: messageId, detail: detail)
            setup.original = (messageId, "$answered")
        }
        return setup
    }

    /// In-Reply-To and References for a reply: from the store, so the window opens at once (offline
    /// too); from the server only for a message whose References aren't stored yet.
    private func replyHeaders(messageId: Int64, detail: MessageDetail) async throws -> (inReplyTo: [String], references: [String]) {
        guard let stored = try store.replyHeaders(id: messageId) else {
            return try await coordinator.replyHeaders(accountId: detail.accountId, remoteId: detail.remoteId)
        }
        guard let own = stored.messageId else { return ([], []) }
        return ([own], Compose.references(
            messageId: [own], references: stored.references.isEmpty ? nil : stored.references,
            inReplyTo: stored.inReplyTo.map { [$0] }))
    }

    /// Sends, then marks the original answered (or forwarded), here and on the server. The drafts it
    /// was written in go once it's sent.
    func send(
        _ message: OutgoingMessage, accountId: String, original: (id: Int64, keyword: String)?, replacingDrafts: [DraftRef] = []
    ) async throws {
        pendingWork += 1  // quitting waits for it
        defer { pendingWork -= 1 }
        let (here, elsewhere) = split(replacingDrafts, accountId: accountId)
        try await coordinator.send(accountId: accountId, message, replacingDrafts: here)
        try? store.deleteMessages(accountId: accountId, remoteIds: here)
        discardDrafts(elsewhere)
        refreshKnownAddresses()  // its recipients now count as written to
        guard let original, let ref = try store.refs(ids: [original.id]).first else { return }
        try store.setKeyword(original.keyword, true, messageIds: [ref.id])
        try? await coordinator.update(
            accountId: ref.accountId, remoteIds: [ref.remoteId], patch: ["keywords/\(original.keyword)": true])
    }

    // MARK: Drafts

    /// A draft on a server.
    struct DraftRef: Hashable {
        var accountId: String
        var remoteId: String
    }

    private func split(_ drafts: [DraftRef], accountId: String) -> (here: [String], elsewhere: [DraftRef]) {
        (drafts.filter { $0.accountId == accountId }.map(\.remoteId), drafts.filter { $0.accountId != accountId })
    }

    /// Saves a message as a draft in the account's Drafts, replacing `old` (earlier saves of it).
    func saveDraft(_ message: OutgoingMessage, accountId: String, replacing old: [DraftRef]) async throws -> DraftRef {
        pendingWork += 1  // quitting waits for it
        defer { pendingWork -= 1 }
        let (here, elsewhere) = split(old, accountId: accountId)
        let id = try await coordinator.saveDraft(accountId: accountId, message, replacing: here)
        try? store.deleteMessages(accountId: accountId, remoteIds: here)  // the replaced ones leave the lists now
        discardDrafts(elsewhere)  // saved before From moved it to another account
        return DraftRef(accountId: accountId, remoteId: id)
    }

    /// Removes drafts not kept: from the lists at once, from the servers in the background.
    func discardDrafts(_ drafts: [DraftRef]) {
        for (accountId, refs) in Dictionary(grouping: drafts, by: \.accountId) {
            let ids = refs.map(\.remoteId)
            try? store.deleteMessages(accountId: accountId, remoteIds: ids)
            inBackground { [coordinator] in try? await coordinator.destroyDrafts(accountId: accountId, ids) }
        }
    }

    /// Opens a draft in a compose window to go on with it (or brings forward the window already editing it).
    func openDraft(messageId: Int64, window: NSWindow?) {
        guard let ref = try? store.refs(ids: [messageId]).first else { return }
        let draft = DraftRef(accountId: ref.accountId, remoteId: ref.remoteId)
        if ComposeWindowController.bringForward(editing: draft) { return }
        Task {
            do {
                let identities = try store.identities()
                guard !identities.isEmpty else { throw ComposeError.noIdentities }
                let saved = try await coordinator.loadDraft(accountId: ref.accountId, remoteId: ref.remoteId)
                let mine = identities.filter { $0.accountId == ref.accountId }
                var setup = ComposeWindowController.Setup(
                    identities: identities, identity: mine.first { $0.email == saved.from } ?? mine.first ?? identities.first,
                    draft: Compose.Draft(to: saved.to, cc: saved.cc, subject: saved.subject, text: saved.text))
                setup.bcc = saved.bcc
                setup.replyTo = saved.replyTo
                // A From of the user's own (Customize…): not an identity's address, or under another name.
                if let from = saved.from, !identities.contains(where: { $0.email == from && $0.name == (saved.fromName ?? $0.name) }) {
                    setup.customFrom = EmailAddress(name: saved.fromName, email: from)
                }
                setup.isMarkdown = saved.isMarkdown
                setup.attachments = saved.attachments
                setup.attachmentsAccountId = ref.accountId
                setup.inReplyTo = saved.inReplyTo
                setup.references = saved.references
                setup.openedDraft = draft
                ComposeWindowController.show(model: self, setup: setup)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn’t open the draft."
                alert.informativeText = Self.describe(error)
                if let window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
            }
        }
    }

    enum ComposeError: LocalizedError {
        case noIdentities

        var errorDescription: String? {
            "No account can send mail yet. Sending addresses appear once an account has synced: a Gmail account, or one on a JMAP server that supports submission."
        }
    }

    /// The message's raw .eml, as a file in a temporary folder (the store keeps it compressed),
    /// downloading it from the server first if needed.
    func rawMessageURL(messageId: Int64) async throws -> URL {
        guard let detail = try store.detail(id: messageId) else { throw CocoaError(.fileNoSuchFile) }
        let (blobs, accountId, blobId) = (store.blobs, detail.accountId, detail.blobId)
        var raw = try await Self.offMain { blobs.read(accountId: accountId, blobId: blobId) }
        if raw == nil {
            let data = try await coordinator.downloadBlob(accountId: accountId, blobId: blobId, type: "message/rfc822", name: "message.eml")
            try await Self.offMain { try blobs.write(data, accountId: accountId, blobId: blobId) }
            raw = data
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Messages", isDirectory: true)
            .appendingPathComponent("\(messageId).eml")
        let message = raw ?? Data()
        try await Self.offMain {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try message.write(to: url, options: .atomic)
        }
        return url
    }

    /// Selects the message's .eml file in Finder (a copy: see `rawMessageURL`).
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
        let (blobs, blobId) = (store.blobs, part.blobId)
        if let cached = try await Self.offMain({ blobs.readPart(accountId: accountId, blobId: blobId) }) { return cached }
        let data = try await coordinator.downloadBlob(accountId: accountId, blobId: blobId, type: part.type, name: part.name ?? "part")
        try await Self.offMain { try? blobs.writePart(data, accountId: accountId, blobId: blobId) }
        return data
    }

    /// An attachment as a file named as the sender named it, in a per-message temporary folder, marked
    /// as downloaded (quarantined) so Gatekeeper checks it before anything runs.
    func attachmentFile(messageId: Int64, index: Int, accountId: String, part: MessagePart) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent("\(messageId)-\(index)", isDirectory: true)
        return try await partFile(accountId: accountId, part: part, in: folder, quarantined: true)
    }

    /// A part as a file in `folder`, named as the sender named it (the one there already, if any): the copy
    /// kept here cloned (instant on APFS, whatever its size), else downloaded first. The file work is off
    /// the main thread: an attachment can be tens of megabytes.
    func partFile(accountId: String, part: MessagePart, in folder: URL, quarantined: Bool) async throws -> URL {
        let url = folder.appendingPathComponent(Self.fileName(for: part))
        let kept = store.blobs.partURL(accountId: accountId, blobId: part.blobId)
        let placed = try await Self.offMain {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            guard FileManager.default.fileExists(atPath: kept.path) else { return false }
            try Self.place(url, quarantined: quarantined) { try FileManager.default.copyItem(at: kept, to: $0) }
            return true
        }
        if placed { return url }
        let data = try await partData(accountId: accountId, part: part)
        try await Self.offMain { try Self.place(url, quarantined: quarantined) { try data.write(to: $0, options: .atomic) } }
        return url
    }

    /// Puts a file at `url` with `write`, its folder made first; one there already (asked for twice at
    /// once) stays.
    nonisolated private static func place(_ url: URL, quarantined: Bool, write: (URL) throws -> Void) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try write(url)
        } catch CocoaError.fileWriteFileExists {
            return
        }
        if quarantined { try quarantine(url) }
    }

    /// File work, off the main thread.
    nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }

    /// A safe file name for a part: the sender's name without path separators, or "Attachment".
    static func fileName(for part: MessagePart) -> String {
        let name = (part.name ?? "").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if !name.isEmpty { return name }
        let ext = UTType(mimeType: part.type)?.preferredFilenameExtension
        return ext.map { "Attachment.\($0)" } ?? "Attachment"
    }

    /// Marks a file as downloaded from the internet by MailMateJ.
    nonisolated static func quarantine(_ url: URL) throws {
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "MailMateJ",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeEmailAttachment as String,
        ]
        var url = url
        try url.setResourceValues(values)
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

    /// How much of the accounts' mail is stored here while any account downloads (accounts done count
    /// as done, so it only grows): messages downloaded and in all; nil when nothing downloads.
    var downloadProgress: (downloaded: Int, total: Int)? {
        guard statuses.values.contains(where: \.isDownloading) else { return nil }
        let counted = statuses.values.filter { $0.total > 0 }
        return (counted.map { min($0.downloaded, $0.total) }.reduce(0, +), counted.map(\.total).reduce(0, +))
    }

    /// Mailboxes (local ids) any download is working on right now.
    var busyMailboxIDs: Set<Int64> { statuses.values.reduce(into: Set<Int64>()) { $0.formUnion($1.busyMailboxes) } }

    /// Whether the account is syncing or downloading messages right now (shows a spinner).
    func isBusy(accountId: String) -> Bool {
        guard let s = statuses[accountId] else { return false }
        return s.phase == .syncing || s.isDownloading
    }

    /// Message headers downloaded and in all, over the accounts still downloading theirs in a first (or
    /// full) sync: just `accountIds`' when given. Nil when none is.
    /// `whole`: they're all fetching whole messages (Gmail), not headers first.
    func headerProgress(accountIds: Set<String>?) -> (downloaded: Int, total: Int, whole: Bool)? {
        let reading = statuses.values.filter { status in
            status.isDownloadingHeaders && status.headersTotal > 0 && (accountIds?.contains(status.accountId) ?? true)
        }
        guard !reading.isEmpty else { return nil }
        return (reading.map(\.headersDownloaded).reduce(0, +), reading.map(\.headersTotal).reduce(0, +),
                reading.allSatisfy(\.headersAreWholeMessages))
    }

    /// "Downloaded X of Y message headers" while an account's first sync lists its mail, then
    /// "Downloaded X of Y messages" while it isn't fully stored locally.
    func downloadInfo(accountId: String) -> String? {
        guard let s = statuses[accountId] else { return nil }
        if s.isDownloadingHeaders, s.headersTotal > 0 {
            let what = s.headersAreWholeMessages ? "messages" : "message headers"
            return "Downloaded \(s.headersDownloaded.formatted()) of \(s.headersTotal.formatted()) \(what)"
        }
        guard s.total > 0, s.downloaded < s.total else { return nil }
        return "Downloaded \(s.downloaded.formatted()) of \(s.total.formatted()) messages"
    }

    /// Coalesces bursts of commits (e.g. during an initial sync) into at most ~3 UI refreshes per second.
    /// Commits a `refreshNow` has shown since (an action's own, refreshed at once) need no refresh again,
    /// which would rebuild the sidebars a second time just after.
    private func scheduleRefresh(committed: ContinuousClock.Instant) {
        latestCommit = max(latestCommit, committed)
        guard !refreshScheduled, committed > refreshedAt else { return }
        refreshScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            refreshScheduled = false
            guard latestCommit > refreshedAt else { return }
            refreshedAt = .now
            let started = Date()
            myAddresses = (try? store.myAddresses()) ?? myAddresses
            dockCounters?.update()
            let counted = Date()
            NotificationCenter.default.post(name: .mailStoreDidChange, object: nil)
            #if DEBUG
                if ProcessInfo.processInfo.environment["MMJ_DEBUG_TIMING"] != nil {
                    let ms = { (a: Date, b: Date) in Int(b.timeIntervalSince(a) * 1000) }
                    NSLog("MMJ timing: refresh on main: addresses+dock \(ms(started, counted)) ms, observers \(ms(counted, Date())) ms")
                }
            #endif
        }
    }

    /// A Gmail account's sign-in: the app's Google client and the account's refresh token.
    nonisolated private static func googleTokens(for account: AccountRecord) throws -> GoogleTokenSource {
        guard let client = googleClient else { throw GmailError.noClient }
        #if DEBUG
            if debugExpiredSignIn == account.id { return GoogleTokenSource(client: client, refreshToken: "expired") }
        #endif
        return GoogleTokenSource(client: client, refreshToken: try Keychain.get(account: account.id))
    }

    #if DEBUG
        var coordinatorForDebug: SyncCoordinator { coordinator }

        /// The Gmail account whose sign-in Google no longer takes, as far as the app is told.
        nonisolated(unsafe) static var debugExpiredSignIn: String?

        /// Fetches an account's first message, body and raw copy, as opening it does; logs how that went.
        func debugFetch(accountId: String) async {
            guard let id = (try? store.messageIDs(scope: .account(accountId)))?.first, let detail = try? store.detail(id: id) else {
                return NSLog("MMJ fetch: no message")
            }
            do {
                _ = try await fetchBody(messageId: id, accountId: accountId)
                NSLog("MMJ fetch body: fetched")
            } catch {
                NSLog("MMJ fetch body: \(error.localizedDescription)")
            }
            do {
                _ = try await coordinator.downloadBlob(accountId: accountId, blobId: detail.blobId, type: "message/rfc822", name: "message.eml")
                NSLog("MMJ fetch raw: fetched")
            } catch {
                NSLog("MMJ fetch raw: \(error.localizedDescription)")
            }
        }

        /// Restarts a Gmail account as signing in again does (without Google's page): with a sign-in
        /// Google refuses (`expired`), or with its own again.
        func debugRestartSignIn(accountId: String, expired: Bool) async {
            guard let account = try? store.account(id: accountId) else { return }
            Self.debugExpiredSignIn = expired ? accountId : nil
            await coordinator.takeOnline(account)
        }

        /// Signs in to a Gmail account over IMAP (read-only) and logs its special mailboxes, how many
        /// messages All Mail has, and a few fetched whole, timing it.
        func debugGmailIMAP(accountId: String) async {
            guard let account = try? store.account(id: accountId), let tokens = try? Self.googleTokens(for: account) else {
                return NSLog("MMJ imap: no account")
            }
            let imap = GmailIMAP(email: account.username, tokens: tokens)
            do {
                let started = Date()
                try await imap.connect()
                let folders = try await imap.folders()
                NSLog("MMJ imap: signed in in \(Int(Date().timeIntervalSince(started) * 1000)) ms; all \(folders.all ?? "-") spam \(folders.spam ?? "-") trash \(folders.trash ?? "-")")
                guard let all = folders.all else { return await imap.close() }
                try await imap.examine(all)
                let indexStarted = Date()
                let index = try await imap.index()
                NSLog("MMJ imap: \(index.count) messages indexed in \(Int(Date().timeIntervalSince(indexStarted) * 1000)) ms")
                let fetchStarted = Date()
                let newest = Array(index.sorted { $0.uid > $1.uid }.prefix(50))
                let messages = try await imap.fetch(newest.map(\.uid), bodies: true)
                let bytes = messages.compactMap(\.raw).map(\.count).reduce(0, +)
                NSLog("MMJ imap: fetched \(messages.count) whole (\(bytes / 1024) KB) in \(Int(Date().timeIntervalSince(fetchStarted) * 1000)) ms; first \(messages.first.map { "\($0.gmailId) thread \($0.threadId ?? "-") labels \($0.labels) flags \($0.flags.sorted())" } ?? "-")")
                await imap.close()
            } catch {
                NSLog("MMJ imap: failed: \(error)")
                await imap.close()
            }
        }
    #endif

    #if DEBUG
        /// Changes a message's read state in Gmail directly (as Gmail on the web would, not through this
        /// app), twice, and logs how long each takes to show here.
        func debugRemoteReadChange(accountId: String, subject: String) async {
            guard let account = try? store.account(id: accountId), let tokens = try? Self.googleTokens(for: account),
                let id = ((try? store.messageIDs(scope: .account(accountId))) ?? []).first(where: { (try? store.detail(id: $0))?.subject == subject }),
                let detail = try? store.detail(id: id)
            else { return NSLog("MMJ remote change: no message") }
            let gmail = GmailClient(tokens: tokens)
            for _ in 0..<2 {
                let wasSeen = (try? store.rows(ids: [id]))?.first?.isSeen ?? false
                do {
                    try await gmail.modify([detail.remoteId], add: wasSeen ? ["UNREAD"] : [], remove: wasSeen ? [] : ["UNREAD"])
                } catch {
                    return NSLog("MMJ remote change: \(error)")
                }
                let started = Date()
                NSLog("MMJ remote change: changing it in Gmail now")
                while Date().timeIntervalSince(started) < 90, (try? store.rows(ids: [id]))?.first?.isSeen == wasSeen {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                let seen = (try? store.rows(ids: [id]))?.first?.isSeen
                NSLog("MMJ remote change: made \(wasSeen ? "unread" : "read") in Gmail, shown here after \(String(format: "%.1f", Date().timeIntervalSince(started))) s (seen now \(String(describing: seen)))")
                try? await Task.sleep(for: .seconds(3))
            }
        }
    #endif

    #if DEBUG
        /// Adds test messages to a Gmail account's Inbox directly (as mail arriving would, not through
        /// this app), logs how long they take to show here, then deletes them for good. More than one
        /// arrive together, as after a night's sleep: added while the account is offline, then taken online.
        func debugRemoteArrival(accountId: String, count: Int = 1) async {
            guard let account = try? store.account(id: accountId), let tokens = try? Self.googleTokens(for: account) else {
                return NSLog("MMJ remote arrival: no account")
            }
            let gmail = GmailClient(tokens: tokens)
            let stamp = Int(Date().timeIntervalSince1970)
            let subjects = (1...max(1, count)).map { "MailMateJ arrival test \(stamp) #\($0)" }
            if count > 1 { await coordinator.takeOffline(accountId) }
            do {
                for subject in subjects {
                    let raw = "From: Test <test@example.com>\r\nTo: \(account.username)\r\nSubject: \(subject)\r\nDate: \(Date().formatted(.dateTime))\r\nMessage-ID: <\(UUID().uuidString)@mailmatej.test>\r\n\r\nArrival test.\r\n"
                    try await gmail.importMessage(Data(raw.utf8), labels: ["INBOX", "UNREAD"])
                }
            } catch {
                NSLog("MMJ remote arrival: \(error)")
            }
            if count > 1 { await coordinator.takeOnline(account) }
            let started = Date()
            NSLog("MMJ remote arrival: \(subjects.count) added in Gmail now")
            var found: [String: String] = [:]  // subject: remote id
            while Date().timeIntervalSince(started) < 120, found.count < subjects.count {
                try? await Task.sleep(for: .milliseconds(200))
                let shown = ((try? store.messageIDs(scope: .account(accountId))) ?? []).prefix(500).compactMap { id in
                    (try? self.store.detail(id: id)).flatMap { subjects.contains($0.subject) ? ($0.subject, $0.remoteId) : nil }
                }
                let before = found.count
                for (subject, remoteId) in shown { found[subject] = remoteId }
                if found.count > before {
                    NSLog("MMJ remote arrival: \(found.count) of \(subjects.count) shown here after \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
                }
            }
            if found.count < subjects.count { NSLog("MMJ remote arrival: only \(found.count) of \(subjects.count) shown") }
            try? await gmail.delete(Array(found.values))  // tidy up
        }
    #endif

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
                let existing = try? store.account(id: "dev-\(name)")
                let record = AccountRecord(
                    id: "dev-\(name)", name: "\(name.capitalized) (local)",
                    sessionURL: "http://localhost:\(ProcessInfo.processInfo.environment["MMJ_DEV_PORT"] ?? "18080")/.well-known/jmap",
                    username: "\(name)@mmj.test",
                    authKind: .basic,
                    // Keep what was set in the account window.
                    fullName: existing?.fullName ?? "", emailAddresses: existing?.emailAddresses ?? "")
                try? store.save(record)  // Upsert, so a changed dev server URL is picked up.
            }
        }
    #endif
}
