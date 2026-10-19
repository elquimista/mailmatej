import AppKit
import UniformTypeIdentifiers
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
            sortOrder: (try store.accounts().map(\.sortOrder).max() ?? -1) + 1,
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
    func updateAccount(_ old: AccountRecord, with draft: AccountDraft) async throws {
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

    /// The sidebar warning for an account that failed to sync, if any.
    func syncWarning(accountId: String) -> String? {
        guard let status = statuses[accountId], case .failed(let message) = status.phase else { return nil }
        #if DEBUG
            return status.errorDetail.map { message + "\n\n" + $0 } ?? message
        #else
            return message
        #endif
    }

    // MARK: Message actions

    enum MessageAction {
        case archive, junk, delete, markRead, markUnread, flag, unflag
    }

    /// Archives, marks as junk, deletes, marks or flags messages: here at once, then on the server.
    /// Messages of several accounts are handled per account. Delete moves to Deleted Messages; messages
    /// already there are deleted for good (after `confirmPermanentDelete` agrees).
    func perform(_ action: MessageAction, on ids: [Int64], confirmPermanentDelete: @escaping (Int) async -> Bool) {
        guard let refs = try? store.refs(ids: ids), !refs.isEmpty else { return }
        Task {
            for (accountId, refs) in Dictionary(grouping: refs, by: \.accountId) {
                do {
                    try await perform(action, accountId: accountId, refs: refs, confirm: confirmPermanentDelete)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Couldn’t change \(refs.count == 1 ? "the message" : "\(refs.count) messages") on the server."
                    alert.informativeText = Self.describe(error)
                    alert.runModal()
                }
            }
        }
    }

    private func perform(
        _ action: MessageAction, accountId: String, refs: [MailStore.MessageRef],
        confirm: (Int) async -> Bool
    ) async throws {
        let ids = refs.map(\.id), remoteIds = refs.map(\.remoteId)
        func setKeyword(_ keyword: String, _ on: Bool) async throws {
            try store.setKeyword(keyword, on, messageIds: ids)
            try await coordinator.update(
                accountId: accountId, remoteIds: remoteIds, patch: ["keywords/\(keyword)": on ? .bool(true) : .null])
        }
        func move(toRole role: String, extra: [String: JSONValue] = [:]) async throws {
            guard let target = try store.mailbox(accountId: accountId, role: role) else {
                throw MessageActionError.noMailbox(role: role)
            }
            try store.moveMessages(ids, toMailboxId: target.id)
            var patch = extra
            patch["mailboxIds"] = .object([target.remoteId: .bool(true)])
            try await coordinator.update(accountId: accountId, remoteIds: remoteIds, patch: patch)
        }
        switch action {
        case .markRead: try await setKeyword("$seen", true)
        case .markUnread: try await setKeyword("$seen", false)
        case .flag: try await setKeyword("$flagged", true)
        case .unflag: try await setKeyword("$flagged", false)
        case .archive: try await move(toRole: "archive")
        case .junk: try await move(toRole: "junk", extra: ["keywords/$junk": .bool(true), "keywords/$notjunk": .null])
        case .delete:
            let inTrash = try store.messageIDs(ids, inRole: "trash")
            let toTrash = refs.filter { !inTrash.contains($0.id) }
            if !toTrash.isEmpty {
                try await moveToTrash(accountId: accountId, refs: toTrash)
            }
            let forGood = refs.filter { inTrash.contains($0.id) }
            if !forGood.isEmpty, await confirm(forGood.count) {
                try await coordinator.destroy(accountId: accountId, remoteIds: forGood.map(\.remoteId))
            }
        }
    }

    private func moveToTrash(accountId: String, refs: [MailStore.MessageRef]) async throws {
        guard let trash = try store.mailbox(accountId: accountId, role: "trash") else {
            throw MessageActionError.noMailbox(role: "trash")
        }
        try store.moveMessages(refs.map(\.id), toMailboxId: trash.id)
        try await coordinator.update(
            accountId: accountId, remoteIds: refs.map(\.remoteId),
            patch: ["mailboxIds": .object([trash.remoteId: .bool(true)])])
    }

    enum MessageActionError: LocalizedError {
        case noMailbox(role: String)

        var errorDescription: String? {
            switch self {
            case .noMailbox(let role):
                let name = ["archive": "an Archive", "junk": "a Junk", "trash": "a Deleted Messages"][role] ?? "a matching"
                return "This account has no \(name) mailbox."
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
        if body?.text == nil { body = try await fetchBody(messageId: messageId, accountId: detail.accountId) }
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
            (setup.inReplyTo, setup.references) = try await coordinator.replyHeaders(
                accountId: detail.accountId, remoteId: detail.remoteId)
            setup.original = (messageId, "$answered")
        }
        return setup
    }

    /// Sends, then marks the original answered (or forwarded), here and on the server.
    func send(_ message: OutgoingMessage, accountId: String, original: (id: Int64, keyword: String)?) async throws {
        try await coordinator.send(accountId: accountId, message)
        guard let original, let ref = try store.refs(ids: [original.id]).first else { return }
        try store.setKeyword(original.keyword, true, messageIds: [ref.id])
        try? await coordinator.update(
            accountId: ref.accountId, remoteIds: [ref.remoteId], patch: ["keywords/\(original.keyword)": true])
    }

    enum ComposeError: LocalizedError {
        case noIdentities

        var errorDescription: String? {
            "No account can send mail yet. Sending addresses appear once an account has synced with a server that supports JMAP submission."
        }
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

    /// An attachment as a file named as the sender named it, in a per-message temporary folder, marked
    /// as downloaded (quarantined) so Gatekeeper checks it before anything runs.
    func attachmentFile(messageId: Int64, index: Int, accountId: String, part: MessagePart) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent("\(messageId)-\(index)", isDirectory: true)
        let url = folder.appendingPathComponent(Self.fileName(for: part))
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let data = try await partData(accountId: accountId, part: part)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try Self.quarantine(url)
        return url
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
    static func quarantine(_ url: URL) throws {
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
                let existing = try? store.account(id: "dev-\(name)")
                let record = AccountRecord(
                    id: "dev-\(name)", name: "\(name.capitalized) (local)",
                    sessionURL: "http://localhost:\(ProcessInfo.processInfo.environment["MMJ_DEV_PORT"] ?? "18080")/.well-known/jmap",
                    username: "\(name)@mmj.test",
                    authKind: .basic, sortOrder: 1000 + i,
                    // Keep what was set in the account window.
                    fullName: existing?.fullName ?? "", emailAddresses: existing?.emailAddresses ?? "")
                try? store.save(record)  // Upsert, so a changed dev server URL is picked up.
            }
        }
    #endif
}
