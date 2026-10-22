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
            Task { @MainActor in AppModel.shared?.scheduleRefresh() }
        }
        myAddresses = (try? store.myAddresses()) ?? []
        createDefaultSmartMailboxes()
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

    /// The sidebar warning for an account that failed to sync, if any, with the changes waiting for it.
    func syncWarning(accountId: String) -> String? {
        guard let status = statuses[accountId], case .failed(var message) = status.phase else { return nil }
        if status.queuedChanges > 0 {
            let changes = status.queuedChanges == 1 ? "1 change" : "\(status.queuedChanges) changes"
            message += "\n\n\(changes) will be made on the server once it can be reached."
        }
        #if DEBUG
            return status.errorDetail.map { message + "\n\n" + $0 } ?? message
        #else
            return message
        #endif
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
        Task {
            for item in work {
                do {
                    try await send(item.server, accountId: item.accountId, refs: item.refs, confirm: confirmPermanentDelete)
                } catch {
                    report(error, count: item.refs.count)
                }
            }
        }
    }

    /// What's left for the server once the local change is made.
    private struct ServerWork {
        var updates: [(remoteIds: [String], patch: [String: JSONValue])] = []
        /// The account has no Archive yet: create it, then move there (here and on the server).
        var archiveIntoNewMailbox = false
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
            for id in ids where !(current[id] ?? []).contains(target.id) {
                try store.setMailboxes((current[id] ?? []) + [target.id], messageId: id)
            }
            work.updates.append((remoteIds, ["mailboxIds/\(target.remoteId)": .bool(true)]))
        case .deletePermanently:
            try store.deleteMessages(accountId: accountId, remoteIds: remoteIds)  // gone here at once
            work.deleteForGood = refs
        case .archive:
            if let archive = try store.mailbox(accountId: accountId, role: "archive") {
                try move(refs, to: archive)
            } else {
                work.archiveIntoNewMailbox = true  // An account without an Archive gets one, as other mail apps do.
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
                for ref in group { try store.setMailboxes(Array(boxes), messageId: ref.id) }
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
            try await coordinator.createMailbox(accountId: accountId, name: "Archive", role: "archive")
            guard let archive = try store.mailbox(accountId: accountId, role: "archive") else {
                throw MessageActionError.noMailbox(role: "archive")
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

    /// Refreshes the UI from the store now, skipping the debounce meant for sync bursts.
    func refreshNow() {
        myAddresses = (try? store.myAddresses()) ?? myAddresses
        dockCounters?.update()
        NotificationCenter.default.post(name: .mailStoreDidChange, object: nil)
    }

    // MARK: Rules

    /// Runs the rules on newly arrived messages, as MailMate does: each rule of a mailbox the messages
    /// are in, in order, on those meeting its conditions (see `runRule`). A message one rule moves
    /// isn't touched by later rules.
    func runRules(accountId: String, remoteIds: [String]) {
        guard let rules = try? store.rules(), rules.contains(where: \.definition.enabled),
            let ids = try? store.messageIDs(accountId: accountId, remoteIds: remoteIds), !ids.isEmpty
        else { return }
        var remaining = Set(ids)
        for rule in rules where rule.parentId == nil && rule.definition.enabled && !remaining.isEmpty {
            let result = runRule(rule, on: Array(remaining), all: rules)
            remaining.subtract(result.moved)
            #if DEBUG
                NSLog("MMJ rules: \(rule.definition.name) matched \(result.matched.count) of \(ids.count) new")
            #endif
        }
    }

    /// Runs one rule on those of `ids` its mailbox and conditions take: its tags and copies at once, then
    /// its subrules on the messages it matched (MailMate's subrules), then — after any Redirect or Forward
    /// has been sent, since they read the message — its first move or delete on what the subrules didn't
    /// move. Returns what it matched and what it (or a subrule) moved away.
    @discardableResult
    func runRule(_ rule: RuleRecord, on ids: [Int64], all: [RuleRecord]? = nil) -> (matched: [Int64], moved: Set<Int64>) {
        guard let matched = try? store.messages(ids, matching: rule), !matched.isEmpty else { return ([], []) }
        let actions = rule.definition.actions.filter(\.enabled)
        let sends = actions.filter { $0.kind == .redirect || $0.kind == .forward }
        for action in actions where !action.kind.moves && !sends.contains(action) { apply(action, to: matched) }
        var moved = Set<Int64>()
        let rules = all ?? ((try? store.rules()) ?? [])
        for child in rules where child.parentId == rule.id && child.definition.enabled {
            moved.formUnion(runRule(child, on: matched.filter { !moved.contains($0) }, all: rules).moved)
        }
        let rest = matched.filter { !moved.contains($0) }
        if let move = actions.first(where: \.kind.moves), !rest.isEmpty {
            if sends.isEmpty {
                apply(move, to: rest)
            } else {
                Task {
                    for action in sends { await send(action, messages: matched) }
                    apply(move, to: rest)
                }
            }
            moved.formUnion(rest)
        } else if !sends.isEmpty {
            Task { for action in sends { await send(action, messages: matched) } }
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
        Task {
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
        try? store.updateSmartMailbox(id: id, definition: definition)
        try? store.moveSmartMailboxFirst(id: id)
        UserDefaults.standard.set(Int(id), forKey: Self.flaggedDefaultsKey)
        let settings = CounterSettings.shared
        for (corner, config) in settings.counters where config.source == MessageScope.flagged.key {
            settings.counters[corner]?.source = MessageScope.smart(id).key
        }
    }

    /// Creates a smart mailbox (inside `parentId`, if given) and shows it at once.
    func createSmartMailbox(name: String, parentId: Int64?) -> Int64? {
        do {
            let id = try store.createSmartMailbox(name: name, parentId: parentId)
            refreshNow()
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
            try store.deleteSmartMailbox(id: id)
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
        Task {
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
        Task {
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
                    authKind: .basic, sortOrder: existing?.sortOrder ?? 1000 + i,  // keep a dragged order
                    // Keep what was set in the account window.
                    fullName: existing?.fullName ?? "", emailAddresses: existing?.emailAddresses ?? "")
                try? store.save(record)  // Upsert, so a changed dev server URL is picked up.
            }
        }
    #endif
}
