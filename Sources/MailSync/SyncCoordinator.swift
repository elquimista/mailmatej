import Foundation
import GmailKit
import JMAPKit
import MailStore
import Network
import os

let syncLog = Logger(subsystem: "app.mailmatej", category: "sync")

public struct AccountSyncStatus: Sendable {
    public enum Phase: Sendable, Equatable {
        case idle
        case syncing
        /// A user-facing message (see `ErrorText.friendly`).
        case failed(String)
    }

    public var accountId: String
    public var phase: Phase
    public var lastSuccess: Date?
    /// The raw error behind `.failed`, for debug builds and logs.
    public var errorDetail: String?
    /// Full-download progress: messages stored locally / messages in the account.
    public var downloaded = 0
    public var total = 0
    public var isDownloading = false
    /// Local mailbox ids the download is working on right now.
    public var busyMailboxes: Set<Int64> = []
    /// Changes made while the server couldn't be reached, waiting to be made there.
    public var queuedChanges = 0
    /// A first (or repeated full) sync's progress: message headers downloaded, and in all.
    public var headersDownloaded = 0
    public var headersTotal = 0
    public var isDownloadingHeaders = false
    /// The first sync fetches whole messages (Gmail), not headers first: one phase, not two.
    public var headersAreWholeMessages = false
    /// Offline, as MailMate's Take Offline makes a source: not synced (its changes wait in the queue)
    /// until Take Online (see `SyncCoordinator.takeOnline`). Kept across launches.
    public var isOffline = false
    /// Offline because Google no longer takes this Gmail account's sign-in (MailMate takes such an
    /// account offline itself): Take Online signs in again first.
    public var needsSignIn = false
}

/// Runs sync for all accounts: a bounded number at a time, triggered by push, polling and the user.
/// Sync requests for an account that is already syncing are coalesced into one follow-up round.
public actor SyncCoordinator {
    public typealias CredentialsProvider = @Sendable (AccountRecord) throws -> Credentials
    /// A Gmail account's sign-in (its refresh token and the app's Google client).
    public typealias GoogleTokensProvider = @Sendable (AccountRecord) throws -> GoogleTokenSource

    private let store: MailStore
    private let credentials: CredentialsProvider
    private let googleTokens: GoogleTokensProvider
    /// New messages of an account, by remote id, after a sync (for rules).
    private let onArrived: @Sendable (String, [String]) -> Void
    private let onStatus: @Sendable (AccountSyncStatus) -> Void
    /// A queued change the server refused once it could be reached (its messages show the server's state).
    private let onQueuedChangeRefused: @Sendable (_ accountId: String, _ error: Error) -> Void
    private let limiter: AsyncLimiter
    private var pathMonitor: NWPathMonitor?
    private let urlSession: URLSession

    private var engines: [String: JMAPAccountSync] = [:]
    /// Gmail accounts: checked every `gmailPollInterval` (more often while the app is in use), and
    /// whenever their Inbox's IMAP IDLE announces something.
    private var gmailEngines: [String: GmailAccountSync] = [:]
    private var gmailPollTasks: [String: Task<Void, Never>] = [:]
    /// Each Gmail account's Inbox watched over IMAP IDLE (what Gmail announces there arrives at once).
    private var gmailWatchTasks: [String: Task<Void, Never>] = [:]
    private let gmailPollInterval: Duration = .seconds(60)
    /// While the app is in use (and 2 minutes after), Gmail accounts are checked this often: Gmail's own
    /// IMAP announces changes made elsewhere late or not at all, while its history (2 quota units a
    /// look) has them at once.
    private let gmailActivePollInterval: Duration = .seconds(10)
    private var inUse = false
    private var leftAt: ContinuousClock.Instant?
    private var lastGmailCheck: [String: ContinuousClock.Instant] = [:]
    /// JMAP accounts: when push last delivered anything (pings too), and when a sync last succeeded.
    private var lastPushSignal: [String: ContinuousClock.Instant] = [:]
    private var lastSynced: [String: ContinuousClock.Instant] = [:]
    private var statuses: [String: AccountSyncStatus] = [:]
    private var running: Set<String> = []
    private var pending: Set<String> = []
    private var pushTasks: [String: Task<Void, Never>] = [:]
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var fastPollTasks: [String: Task<Void, Never>] = [:]
    /// How often an account is checked for new mail while its push doesn't work.
    private let fastPollInterval: Duration = .seconds(20)
    /// Full downloads run for at most this many accounts at a time, separately from syncing.
    private let downloadLimiter = AsyncLimiter(limit: 3)
    /// Gmail's quota is per account (and each paces itself), so more of them download at once.
    private let gmailDownloadLimiter = AsyncLimiter(limit: 10)
    /// Gmail full syncs (every message fetched whole: hours for an old account) take their rounds a few
    /// accounts at a time, apart from the slots other syncs use.
    private let gmailFullSyncLimiter = AsyncLimiter(limit: 3)
    /// Each account's changes go to its server one at a time, in the order they were made: two at once
    /// to the same message (read, then archived straight away) can be refused, or land the wrong way round.
    private var changeTurns: [String: AsyncLimiter] = [:]
    private var pollTask: Task<Void, Never>?

    public init(
        store: MailStore, maxConcurrentSyncs: Int = 6, credentials: @escaping CredentialsProvider,
        googleTokens: @escaping GoogleTokensProvider = { _ in throw GoogleOAuthError.signInExpired },
        onStatus: @escaping @Sendable (AccountSyncStatus) -> Void = { _ in },
        onArrived: @escaping @Sendable (_ accountId: String, _ remoteIds: [String]) -> Void = { _, _ in },
        onQueuedChangeRefused: @escaping @Sendable (_ accountId: String, _ error: Error) -> Void = { _, _ in }
    ) {
        self.store = store
        self.onQueuedChangeRefused = onQueuedChangeRefused
        self.credentials = credentials
        self.googleTokens = googleTokens
        self.onStatus = onStatus
        self.onArrived = onArrived
        self.limiter = AsyncLimiter(limit: maxConcurrentSyncs)
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        self.urlSession = URLSession(configuration: config)
    }

    /// Loads all enabled accounts, syncs them, and keeps them current with push plus a fallback poll.
    public func start(pollInterval: Duration = .seconds(300), push: Bool = true) throws {
        try store.retryFailedDownloads()
        try loadAccounts(push: push)
        syncAll()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                await self?.checkAll()
            }
        }
        pathMonitor?.cancel()
        let monitor = NWPathMonitor()
        nonisolated(unsafe) var wasSatisfied = true
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            defer { wasSatisfied = satisfied }
            guard satisfied, !wasSatisfied else { return }
            Task { await self?.networkReturned() }
        }
        monitor.start(queue: DispatchQueue(label: "app.mailmatej.path"))
        pathMonitor = monitor
    }

    /// Creates engines for all enabled accounts without syncing them.
    public func loadAccounts(push: Bool) throws {
        for account in try store.accounts() where account.isEnabled && engines[account.id] == nil && gmailEngines[account.id] == nil {
            register(account, push: push)
        }
    }

    public func stop() {
        pollTask?.cancel()
        pathMonitor?.cancel()
        for task in downloadTasks.values { task.cancel() }
        downloadTasks.removeAll()
        for task in fastPollTasks.values { task.cancel() }
        for task in gmailPollTasks.values { task.cancel() }
        for task in gmailWatchTasks.values { task.cancel() }
        fastPollTasks.removeAll()
        for task in pushTasks.values { task.cancel() }
        pushTasks.removeAll()
    }

    public func addAccount(_ account: AccountRecord) {
        register(account, push: true)
        requestSync(account.id)
    }

    public func removeAccount(id: String) {
        pushTasks.removeValue(forKey: id)?.cancel()
        downloadTasks.removeValue(forKey: id)?.cancel()
        fastPollTasks.removeValue(forKey: id)?.cancel()
        engines.removeValue(forKey: id)
        gmailEngines.removeValue(forKey: id)
        gmailPollTasks.removeValue(forKey: id)?.cancel()
        gmailWatchTasks.removeValue(forKey: id)?.cancel()
        statuses.removeValue(forKey: id)
        pending.remove(id)
    }

    public func syncAll() {
        for id in Array(engines.keys) + Array(gmailEngines.keys) { requestSync(id) }
    }

    /// The timed check: an account whose push is delivering (a signal, even a ping, within the last
    /// `pushHealthy`) is left to it, but for a sync every `pushedCheckInterval` in case it missed
    /// something; Gmail accounts have checks of their own (`checkGmailIfDue`).
    private func checkAll() {
        let now = ContinuousClock.now
        for id in engines.keys where !Self.leftToPush(lastSignal: lastPushSignal[id], lastSynced: lastSynced[id], now: now) {
            requestSync(id)
        }
    }

    static func leftToPush(lastSignal: ContinuousClock.Instant?, lastSynced: ContinuousClock.Instant?, now: ContinuousClock.Instant) -> Bool {
        guard let lastSignal, let lastSynced else { return false }
        return now - lastSignal < pushHealthy && now - lastSynced < pushedCheckInterval
    }

    static let pushHealthy: Duration = .seconds(90)  // push pings every 30 s
    static let pushedCheckInterval: Duration = .seconds(1800)

    /// Back online: everything syncs, which first makes the changes queued meanwhile, and push and
    /// Gmail's watches waiting to try again (longer after each failure, up to 5 minutes) connect now.
    private func networkReturned() {
        for (id, engine) in engines where pushTasks[id] != nil && fastPollTasks[id] != nil { startPush(id, engine: engine) }
        for (id, engine) in gmailEngines where gmailWatchTasks[id] != nil { watchGmail(id, engine: engine) }
        syncAll()
    }

    public func requestSync(_ accountId: String) {
        guard engines[accountId] != nil || gmailEngines[accountId] != nil, statuses[accountId]?.isOffline != true else { return }
        if running.contains(accountId) {
            pending.insert(accountId)
            return
        }
        running.insert(accountId)
        Task { await runSync(accountId) }
    }

    // MARK: Offline

    /// Where an offline account is remembered (see `AccountSyncStatus.isOffline`): "user" when taken
    /// offline with Take Offline, else Google refused its sign-in.
    static let offlineState = "Offline"

    /// Take Offline: the account stops syncing (push, checks, downloads) until Take Online.
    public func takeOffline(_ accountId: String) {
        guard engines[accountId] != nil || gmailEngines[accountId] != nil else { return }
        try? store.setSyncState("user", accountId: accountId, type: Self.offlineState)
        stopSyncing(accountId)
        update(accountId, .idle, offline: true, needsSignIn: false)
    }

    /// Takes a Gmail account offline when Google refuses its sign-in, as MailMate does: until Take
    /// Online signs in again.
    private func takeOffline(_ accountId: String, because error: Error) {
        try? store.setSyncState("signIn", accountId: accountId, type: Self.offlineState)
        stopSyncing(accountId)
        update(accountId, .failed(ErrorText.friendly(error)), detail: ErrorText.technical(error), offline: true, needsSignIn: true)
    }

    private func stopSyncing(_ accountId: String) {
        pushTasks.removeValue(forKey: accountId)?.cancel()
        fastPollTasks.removeValue(forKey: accountId)?.cancel()
        gmailWatchTasks.removeValue(forKey: accountId)?.cancel()
        gmailPollTasks.removeValue(forKey: accountId)?.cancel()
        downloadTasks.removeValue(forKey: accountId)?.cancel()
    }

    /// What an offline account can't do: fetch what isn't downloaded yet (a message, an attachment).
    public struct AccountOffline: LocalizedError {
        public let accountName: String
        public var errorDescription: String? {
            "“\(accountName)” is offline, and this isn’t downloaded yet. Take it online to download it."
        }
    }

    /// Offline accounts don't reach their server, even for what's asked for there and then.
    private func refuseIfOffline(_ accountId: String) throws {
        guard statuses[accountId]?.isOffline == true else { return }
        throw AccountOffline(accountName: (try? store.account(id: accountId))?.name ?? accountId)
    }

    /// An account left offline stays so at launch (see `offlineState`); false when it's online.
    private func staysOffline(_ accountId: String) -> Bool {
        guard let state = try? store.syncState(accountId: accountId, type: Self.offlineState) else { return false }
        if state == "user" {
            update(accountId, .idle, offline: true, needsSignIn: false)
        } else {
            takeOffline(accountId, because: GoogleOAuthError.signInExpired)  // still: only signing in helps
        }
        reportQueue(accountId)  // the changes still waiting for it
        return true
    }

    /// Take Online: an offline account starts over, showing as syncing at once, and first makes the
    /// changes queued while it was offline. For a Gmail account Google refused the sign-in of, that's
    /// once it's signed in again (its new refresh token in the keychain).
    public func takeOnline(_ account: AccountRecord) {
        try? store.setSyncState(nil, accountId: account.id, type: Self.offlineState)
        downloadTasks.removeValue(forKey: account.id)?.cancel()  // started with the old sign-in
        register(account, push: true)
        update(account.id, .syncing, offline: false, needsSignIn: false)
        requestSync(account.id)
    }

    #if DEBUG
        public func debugGmailIMAPFlags(accountId: String, remoteId: String) async throws -> [Set<String>] {
            try await gmailEngines[accountId]?.debugIMAPFlags(remoteId: remoteId) ?? []
        }

        public func debugGmailFlags(accountId: String, fromScratch: Bool) async throws {
            try await gmailEngines[accountId]?.debugCheckFlags(fromScratch: fromScratch)
        }

        public func debugGmailStoreFlag(accountId: String, remoteId: String, flag: String, add: Bool) async throws {
            try await gmailEngines[accountId]?.debugStoreFlag(remoteId: remoteId, flag: flag, add: add)
        }

        public func debugGmailDrafts(accountId: String) async throws -> [String] {
            try await gmailEngines[accountId]?.debugDraftMessageIds() ?? []
        }
    #endif

    /// Runs one sync round right now (bypassing coalescing). Used by the CLI.
    public func syncNow(_ accountId: String) async throws -> JMAPAccountSync.Result {
        guard let engine = engines[accountId] else { throw JMAPError.invalidResponse("unknown account") }
        return try await engine.sync()
    }

    public func downloadBlob(accountId: String, blobId: String, type: String, name: String) async throws -> Data {
        try refuseIfOffline(accountId)
        if let gmail = gmailEngines[accountId] { return try await gmail.downloadBlob(blobId: blobId, type: type, name: name) }
        guard let engine = engines[accountId] else { throw notLoaded(accountId) }
        return try await engine.downloadBlob(blobId: blobId, type: type, name: name)
    }

    public func fetchBody(messageId: Int64, accountId: String) async throws -> MessageBody {
        try refuseIfOffline(accountId)
        if let gmail = gmailEngines[accountId] { return try await gmail.fetchBody(messageId: messageId) }
        guard let engine = engines[accountId] else { throw notLoaded(accountId) }
        return try await engine.fetchBody(messageId: messageId)
    }

    /// Changes emails on the server (see `JMAPAccountSync.update`), then syncs so mailbox counts follow.
    /// Changes messages on the server (Email/set), or queues the change while it can't be reached.
    public func update(accountId: String, remoteIds: [String], patch: [String: JSONValue]) async throws {
        guard !remoteIds.isEmpty else { return }
        defer { requestSync(accountId) }
        try await makeOrQueue(.update(remoteIds: remoteIds, patch: patch), accountId: accountId)
    }

    /// See `JMAPAccountSync.ensureIdentities`.
    public func ensureIdentities(accountId: String, addresses: [String], name: String) async throws
        -> [(email: String, reason: String)]
    {
        if let gmail = gmailEngines[accountId] { return try await gmail.ensureIdentities(addresses, name: name) }
        guard let engine = engines[accountId] else { throw notLoaded(accountId) }
        return try await engine.ensureIdentities(addresses, name: name)
    }

    /// Makes a mailbox on the server; `pending`: the stand-in shown meanwhile (see `MailStore.addPendingMailbox`).
    public func createMailbox(
        accountId: String, name: String, role: String?, parentRemoteId: String? = nil, replacing pending: String? = nil
    ) async throws {
        if let gmail = gmailEngines[accountId] {
            return try await gmail.createMailbox(name: name, role: role, parentRemoteId: parentRemoteId, replacing: pending)
        }
        guard let engine = engines[accountId] else { throw notLoaded(accountId) }
        try await engine.createMailbox(name: name, role: role, parentRemoteId: parentRemoteId, replacing: pending)
    }

    /// Deletes mailboxes on the server, each after those inside it (`remoteIds` in that order).
    public func deleteMailboxes(accountId: String, remoteIds: [String]) async throws {
        if let gmail = gmailEngines[accountId] { return try await gmail.deleteMailboxes(remoteIds: remoteIds) }
        guard let engine = engines[accountId] else { throw notLoaded(accountId) }
        try await engine.deleteMailboxes(remoteIds: remoteIds)
    }

    /// Copies a whole message into a mailbox of `accountId` (see `JMAPAccountSync.importMessage`).
    public func importMessage(
        accountId: String, _ raw: Data, mailboxRemoteId: String, keywords: [String], receivedAt: Date
    ) async throws {
        try await importInto(accountId, raw, mailboxRemoteId: mailboxRemoteId, keywords: keywords, receivedAt: receivedAt)
        requestSync(accountId)  // brings it in (one sync for many copied at once)
    }

    private func importInto(
        _ accountId: String, _ raw: Data, mailboxRemoteId: String, keywords: [String], receivedAt: Date
    ) async throws {
        if let gmail = gmailEngines[accountId] {
            return try await gmail.importMessage(raw, mailboxRemoteId: mailboxRemoteId, keywords: keywords, receivedAt: receivedAt)
        }
        guard let engine = engines[accountId] else { throw notLoaded(accountId) }
        try await engine.importMessage(raw, mailboxRemoteId: mailboxRemoteId, keywords: keywords, receivedAt: receivedAt)
    }

    public func restore(accountId: String, remoteIds: [String]) async throws {
        if let gmail = gmailEngines[accountId] { return try await gmail.restore(remoteIds: remoteIds) }
        guard let engine = engines[accountId] else { throw notLoaded(accountId) }
        try await engine.restore(remoteIds: remoteIds)
    }

    /// Deletes messages for good, or queues that while the server can't be reached.
    public func destroy(accountId: String, remoteIds: [String]) async throws {
        guard !remoteIds.isEmpty else { return }
        defer { requestSync(accountId) }
        try await makeOrQueue(.destroy(remoteIds: remoteIds), accountId: accountId)
    }

    /// Moves a message to another account: imports its raw message (which must be stored locally, so
    /// the move can wait in the queue) into the target mailbox, then deletes the original. Queued while
    /// either server can't be reached.
    public func moveAcross(
        accountId: String, remoteId: String, blobId: String, toAccount targetAccountId: String, mailboxRemoteId: String,
        keywords: [String], receivedAt: Date
    ) async throws {
        defer { requestSync(accountId) }
        try await makeOrQueue(
            .moveAcross(
                remoteId: remoteId, blobId: blobId, targetAccountId: targetAccountId, mailboxRemoteId: mailboxRemoteId,
                keywords: keywords, receivedAt: receivedAt),
            accountId: accountId)
    }

    // MARK: Change queue

    /// Runs `work` once the account's changes before it are done (see `changeTurns`).
    private func inTurn<T>(_ accountId: String, _ work: () async throws -> T) async throws -> T {
        let turn = changeTurns[accountId] ?? AsyncLimiter(limit: 1)
        changeTurns[accountId] = turn
        await turn.acquire()
        do {
            let result = try await work()
            await turn.release()
            return result
        } catch {
            await turn.release()
            throw error
        }
    }

    /// Makes a change on the server once the account's earlier ones are done, unless older changes are
    /// still queued (it waits behind them, so changes reach the server in the order they were made) or
    /// the server can't be reached.
    private func makeOrQueue(_ change: QueuedChange, accountId: String) async throws {
        try await inTurn(accountId) { try await makeOrQueueInTurn(change, accountId: accountId) }
    }

    private func makeOrQueueInTurn(_ change: QueuedChange, accountId: String) async throws {
        if try statuses[accountId]?.isOffline == true || store.queuedChangeCount(accountId: accountId) > 0 {
            return try enqueue(change, accountId: accountId)
        }
        do {
            if let rest = try await make(change, accountId: accountId) { try enqueue(rest, accountId: accountId) }
        } catch where Self.canWait(error) {
            try enqueue(change, accountId: accountId)
        }
    }

    /// Whether a change that failed can wait in the queue: the server can't be reached, or Google wants
    /// the (Gmail) account signed in to again, after which it goes through.
    private static func canWait(_ error: Error) -> Bool {
        ErrorText.isUnreachable(error) || error as? GoogleOAuthError == .signInExpired
    }

    private func enqueue(_ change: QueuedChange, accountId: String) throws {
        try store.enqueueChange(accountId: accountId, try JSONEncoder().encode(change))
        syncLog.notice("Queued a change for \(accountId, privacy: .public): it can't be made now")
        reportQueue(accountId)
    }

    /// Makes one change. Returns what's left of it when part went through and the rest couldn't (a move's
    /// delete after its copy was confirmed), so a retry doesn't copy the message twice.
    private func make(_ change: QueuedChange, accountId: String) async throws -> QueuedChange? {
        let gmail = gmailEngines[accountId]
        let engine = engines[accountId]
        guard gmail != nil || engine != nil else { throw notLoaded(accountId) }
        func destroy(_ remoteIds: [String]) async throws {
            if let gmail { try await gmail.destroy(remoteIds: remoteIds) } else { try await engine!.destroy(remoteIds: remoteIds) }
        }
        switch change {
        case .update(let remoteIds, let patch):
            if let gmail { try await gmail.update(remoteIds: remoteIds, patch: patch) } else { try await engine!.update(remoteIds: remoteIds, patch: patch) }
        case .destroy(let remoteIds):
            try await destroy(remoteIds)
        case .moveAcross(let remoteId, let blobId, let targetAccountId, let mailboxRemoteId, let keywords, let receivedAt):
            guard let raw = store.blobs.read(accountId: accountId, blobId: blobId) else {
                throw JMAPError.invalidResponse("the message isn’t stored locally")
            }
            try await importInto(targetAccountId, raw, mailboxRemoteId: mailboxRemoteId, keywords: keywords, receivedAt: receivedAt)
            requestSync(targetAccountId)
            do {
                try await destroy([remoteId])
            } catch where Self.canWait(error) {
                return .destroy(remoteIds: [remoteId])
            }
        }
        return nil
    }

    /// Makes the account's queued changes, oldest first. Throws at the first one the server still can't
    /// be reached for (the sync waits too, so it can't bring back the server's older state over local
    /// changes). One the server refuses is dropped, its messages back to the server's state, and reported.
    private func flushQueue(_ accountId: String) async throws {
        try await inTurn(accountId) { try await flushQueueInTurn(accountId) }
    }

    private func flushQueueInTurn(_ accountId: String) async throws {
        let queued = try store.queuedChanges(accountId: accountId)
        guard !queued.isEmpty else { return }
        defer { reportQueue(accountId) }
        for item in queued {
            guard let change = try? JSONDecoder().decode(QueuedChange.self, from: item.change) else {
                try store.removeQueuedChange(id: item.id)
                continue
            }
            do {
                if let rest = try await make(change, accountId: accountId) {
                    try store.replaceQueuedChange(id: item.id, with: try JSONEncoder().encode(rest))
                    throw URLError(.networkConnectionLost)
                }
                try store.removeQueuedChange(id: item.id)
            } catch where Self.canWait(error) {
                throw error
            } catch {
                syncLog.error("A queued change was refused: \(ErrorText.technical(error), privacy: .public)")
                try store.removeQueuedChange(id: item.id)
                // Back to the server's state: refused updates are fetched again by the engine; messages
                // not deleted, or not moved, come back.
                switch change {
                case .update: break
                case .destroy(let remoteIds): try? await restore(accountId: accountId, remoteIds: remoteIds)
                case .moveAcross(let remoteId, _, _, _, _, _): try? await restore(accountId: accountId, remoteIds: [remoteId])
                }
                onQueuedChangeRefused(accountId, error)
            }
        }
    }

    private func reportQueue(_ accountId: String) {
        var status = statuses[accountId] ?? AccountSyncStatus(accountId: accountId, phase: .idle, lastSuccess: nil)
        status.queuedChanges = (try? store.queuedChangeCount(accountId: accountId)) ?? 0
        statuses[accountId] = status
        onStatus(status)
    }

    /// Sends a message from the account (see `JMAPAccountSync.send`), then syncs so it shows in Sent.
    public func send(accountId: String, _ message: OutgoingMessage, replacingDrafts: [String] = []) async throws {
        defer { requestSync(accountId) }
        if let gmail = gmailEngines[accountId] { return try await gmail.send(message, replacingDrafts: replacingDrafts) }
        guard let engine = engines[accountId] else { throw notLoaded(accountId) }
        try await engine.send(message, replacingDrafts: replacingDrafts)
    }

    /// Saves a draft (see `JMAPAccountSync.saveDraft`), then syncs so it shows in Drafts.
    public func saveDraft(accountId: String, _ message: OutgoingMessage, replacing old: [String]) async throws -> String {
        defer { requestSync(accountId) }
        if let gmail = gmailEngines[accountId] { return try await gmail.saveDraft(message, replacing: old) }
        guard let engine = engines[accountId] else { throw notLoaded(accountId) }
        return try await engine.saveDraft(message, replacing: old)
    }

    public func destroyDrafts(accountId: String, _ remoteIds: [String]) async throws {
        if let gmail = gmailEngines[accountId] { return try await gmail.destroyDrafts(remoteIds) }
        guard let engine = engines[accountId] else { throw notLoaded(accountId) }
        try await engine.destroyDrafts(remoteIds)
    }

    public func loadDraft(accountId: String, remoteId: String) async throws -> SavedDraft {
        if let gmail = gmailEngines[accountId] { return try await gmail.loadDraft(remoteId: remoteId) }
        guard let engine = engines[accountId] else { throw notLoaded(accountId) }
        return try await engine.loadDraft(remoteId: remoteId)
    }

    public func renameMailbox(accountId: String, remoteId: String, to name: String) async throws {
        if let gmail = gmailEngines[accountId] { return try await gmail.renameMailbox(remoteId: remoteId, to: name) }
        guard let engine = engines[accountId] else { throw notLoaded(accountId) }
        try await engine.renameMailbox(remoteId: remoteId, to: name)
    }

    public func redirect(accountId: String, remoteId: String, to recipients: [String], identityId: String, mailFrom: String) async throws {
        if let gmail = gmailEngines[accountId] { return try await gmail.redirect(remoteId: remoteId, to: recipients, mailFrom: mailFrom) }
        guard let engine = engines[accountId] else { throw notLoaded(accountId) }
        try await engine.redirect(remoteId: remoteId, to: recipients, identityId: identityId, mailFrom: mailFrom)
    }

    public func replyHeaders(accountId: String, remoteId: String) async throws -> (inReplyTo: [String], references: [String]) {
        if let gmail = gmailEngines[accountId] { return try await gmail.replyHeaders(remoteId: remoteId) }
        guard let engine = engines[accountId] else { throw notLoaded(accountId) }
        return try await engine.replyHeaders(remoteId: remoteId)
    }

    // MARK: Private

    private func register(_ account: AccountRecord, push: Bool) {
        if account.isGmail { return registerGmail(account, poll: push) }
        do {
            let engine = try JMAPAccountSync(
                account: account, credentials: try credentials(account), store: store, urlSession: urlSession)
            engines[account.id] = engine
            if !staysOffline(account.id), push { startPush(account.id, engine: engine) }
        } catch {
            update(account.id, failure: error)
        }
    }

    /// A Gmail account: its Inbox watched over IMAP IDLE (changes made elsewhere arrive within
    /// seconds), and checked every `gmailPollInterval` in any case (a few short requests to Gmail's
    /// history), so a watch that stops working costs at most a minute's delay.
    private func registerGmail(_ account: AccountRecord, poll: Bool) {
        let engine: GmailAccountSync
        do {
            engine = GmailAccountSync(account: account, tokens: try googleTokens(account), store: store, urlSession: urlSession)
            gmailEngines[account.id] = engine
        } catch {
            return update(account.id, failure: error)
        }
        guard !staysOffline(account.id), poll else { return }
        watchGmail(account.id, engine: engine)
        gmailPollTasks[account.id]?.cancel()
        gmailPollTasks[account.id] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self?.checkGmailIfDue(account.id)
            }
        }
    }

    private func watchGmail(_ accountId: String, engine: GmailAccountSync) {
        gmailWatchTasks[accountId]?.cancel()
        gmailWatchTasks[accountId] = Task { [weak self] in
            await engine.watch { [weak self] in Task { [weak self] in await self?.requestSync(accountId) } }
        }
    }

    /// The app is in use (frontmost) or not: Gmail accounts are checked every 10 s while it is, and for
    /// 2 minutes after, else every minute. Coming back checks them at once.
    public func setInUse(_ active: Bool) {
        if active {
            if !inUse { for id in gmailEngines.keys { requestSync(id) } }
            inUse = true
            leftAt = nil
        } else if inUse {
            inUse = false
            leftAt = .now
        }
    }

    private var gmailInterval: Duration {
        if inUse || leftAt.map({ ContinuousClock.now - $0 < .seconds(120) }) == true { return gmailActivePollInterval }
        return gmailPollInterval
    }

    private func checkGmailIfDue(_ accountId: String) {
        guard let last = lastGmailCheck[accountId] else { return requestSync(accountId) }
        if ContinuousClock.now - last >= gmailInterval { requestSync(accountId) }
    }

    /// A Gmail check that's taking a while shows as syncing (a quick one, every 10 s, doesn't flicker).
    private func showSyncing(_ accountId: String) {
        guard running.contains(accountId), statuses[accountId]?.phase != .syncing, statuses[accountId]?.isOffline != true else { return }
        update(accountId, .syncing)
    }

    private func runSync(_ accountId: String) async {
        repeat {
            pending.remove(accountId)
            if statuses[accountId]?.isOffline == true { break }
            if let gmail = gmailEngines[accountId] {
                // A full sync goes in rounds (see `GmailAccountSync.fullSync`), taking turns with other
                // accounts' full syncs, never holding a slot that checks for new mail and sending changes
                // wait for.
                let slots = (try? await gmail.listsEverything()) == true ? gmailFullSyncLimiter : limiter
                await slots.acquire()
                lastGmailCheck[accountId] = .now
                let spinner = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1.5))
                    if !Task.isCancelled { await self?.showSyncing(accountId) }
                }
                defer { spinner.cancel() }
                do {
                    try await flushQueue(accountId)
                    // Rules run on new mail as each message is stored (it can take a while for many).
                    let result = try await gmail.sync(
                        progress: { [weak self] downloaded, total in
                            await self?.reportHeaders(accountId, downloaded: downloaded, total: total, whole: true)
                        },
                        arrived: { [onArrived] remoteIds in onArrived(accountId, remoteIds) })
                    if result.unfinished {
                        pending.insert(accountId)  // the next round, after those waiting for theirs
                    } else {
                        endHeaders(accountId)
                        update(accountId, .idle, success: true)
                        startDownloads(accountId)
                    }
                } catch {
                    endHeaders(accountId)
                    update(accountId, failure: error)
                }
                await slots.release()
                continue
            }
            guard let engine = engines[accountId] else { break }
            await limiter.acquire()
            update(accountId, .syncing)
            do {
                try await flushQueue(accountId)
                let result = try await engine.sync { [weak self] downloaded, total in
                    await self?.reportHeaders(accountId, downloaded: downloaded, total: total)
                }
                endHeaders(accountId)
                if !result.arrived.isEmpty { onArrived(accountId, result.arrived) }
                lastSynced[accountId] = .now
                update(accountId, .idle, success: true)
                startDownloads(accountId)
            } catch {
                endHeaders(accountId)
                update(accountId, failure: error)
            }
            await limiter.release()
        } while pending.contains(accountId)
        running.remove(accountId)
    }

    /// A full sync's progress, as the engine downloads message headers (called in order, from within
    /// its sync, so it never comes after `endHeaders`).
    private func reportHeaders(_ accountId: String, downloaded: Int, total: Int, whole: Bool = false) {
        #if DEBUG
            if ProcessInfo.processInfo.environment["MMJ_DEBUG_GMAIL"] != nil { NSLog("MMJ header progress \(accountId): \(downloaded) of \(total)") }
        #endif
        var status = statuses[accountId] ?? AccountSyncStatus(accountId: accountId, phase: .syncing, lastSuccess: nil)
        status.isDownloadingHeaders = true
        status.headersAreWholeMessages = whole
        status.headersDownloaded = downloaded
        status.headersTotal = max(total, downloaded)
        statuses[accountId] = status
        onStatus(status)
    }

    private func endHeaders(_ accountId: String) {
        guard var status = statuses[accountId], status.isDownloadingHeaders else { return }
        status.isDownloadingHeaders = false
        statuses[accountId] = status
        onStatus(status)
    }

    // MARK: Full download

    /// Starts downloading the account's messages that aren't stored locally yet (no-op if running).
    public func startDownloads(_ accountId: String) {
        guard downloadTasks[accountId] == nil, statuses[accountId]?.isOffline != true else { return }
        if let gmail = gmailEngines[accountId] {
            downloadTasks[accountId] = Task {
                // No pause between batches: Gmail's limit is per request, and the requests pace themselves.
                await downloadLoop(accountId, name: gmail.account.name, gmail: true) { try await gmail.downloadNextBatch() }
            }
        } else if let engine = engines[accountId] {
            downloadTasks[accountId] = Task {
                await downloadLoop(accountId, name: engine.account.name) { try await engine.downloadNextBatch() }
            }
        }
    }

    private func downloadLoop(
        _ accountId: String, name: String, gmail: Bool = false, next: @escaping () async throws -> JMAPAccountSync.DownloadBatchResult
    ) async {
        let limiter = gmail ? gmailDownloadLimiter : downloadLimiter
        reportDownloadProgress(accountId, active: true)
        var backoff = 5.0
        downloading: while !Task.isCancelled {
            // A slot per batch, not per download: accounts take turns, so one account's first download
            // never holds back another's new mail (which shows only once it's downloaded).
            await limiter.acquire()
            #if DEBUG
                // A slow server's downloads, to see new mail show up only once it's downloaded.
                if let seconds = Double(ProcessInfo.processInfo.environment["MMJ_DEBUG_SLOW_DOWNLOAD"] ?? "") {
                    try? await Task.sleep(for: .seconds(seconds))
                }
            #endif
            let outcome: Swift.Result<JMAPAccountSync.DownloadBatchResult, Error>
            do {
                reportBusyMailboxes(accountId, (try? store.mailboxIdsOfPendingDownloads(accountId: accountId, limit: 25)) ?? [])
                outcome = .success(try await next())
            } catch {
                outcome = .failure(error)
            }
            await limiter.release()
            switch outcome {
            case .success(let result):
                reportDownloadProgress(accountId, active: true)
                if result.processed == 0 { break downloading }
                // On at once: accounts take turns by the slot, and a server that pushes back (rate limits)
                // fails a batch, which waits below.
                backoff = 5
            case .failure(let error):
                syncLog.error("Download failed for \(name, privacy: .public): \(ErrorText.technical(error), privacy: .public)")
                if backoff > 600 { break downloading }  // Give up until the next sync restarts it.
                try? await Task.sleep(for: .seconds(backoff))
                backoff *= 2
            }
        }
        // A cancelled one was taken off by whoever cancelled it, who may have started another since.
        guard !Task.isCancelled else { return }
        downloadTasks[accountId] = nil
        reportBusyMailboxes(accountId, [])
        reportDownloadProgress(accountId, active: false)
    }

    private func reportBusyMailboxes(_ accountId: String, _ ids: Set<Int64>) {
        var status = statuses[accountId] ?? AccountSyncStatus(accountId: accountId, phase: .idle, lastSuccess: nil)
        guard status.busyMailboxes != ids else { return }
        status.busyMailboxes = ids
        statuses[accountId] = status
        onStatus(status)
    }

    private func reportDownloadProgress(_ accountId: String, active: Bool) {
        guard let progress = try? store.downloadProgress(accountId: accountId) else { return }
        var status = statuses[accountId] ?? AccountSyncStatus(accountId: accountId, phase: .idle, lastSuccess: nil)
        status.downloaded = progress.downloaded
        status.total = progress.total
        status.isDownloading = active && progress.downloaded < progress.total
        statuses[accountId] = status
        onStatus(status)
    }

    /// Keeps a push connection open: WebSocket first (proxies don't buffer it), EventSource as the
    /// fallback. A connection that delivers nothing at all — not even the server's pings — counts as
    /// broken; while push is broken the account is checked for new mail every 20 s instead. Once push
    /// connects again after a drop, the account syncs at once.
    private func startPush(_ accountId: String, engine: JMAPAccountSync) {
        pushTasks[accountId]?.cancel()
        pushTasks[accountId] = Task { [weak self] in
            let name = engine.account.name
            var transport: JMAPAccountSync.PushTransport = await engine.supportsWebSocketPush() ? .webSocket : .eventSource
            var backoff: Double = 5
            var reconnecting = false
            while !Task.isCancelled {
                let started = ContinuousClock.now
                var signals = 0
                var failure: String?
                do {
                    let stream = try await engine.pushSignals(transport)
                    syncLog.notice("Push connecting over \(transport.rawValue, privacy: .public) for \(name, privacy: .public)")
                    // Connected again after a drop, so the server is back (restarted, say): the sync that
                    // failed while it was away runs again now, clearing its warning and catching up on what
                    // changed, rather than waiting for new mail or the next check (the first ping is 30 s off).
                    if reconnecting { await self?.requestSync(accountId) }
                    for try await signal in stream {
                        signals += 1
                        await self?.pushSignalled(accountId)
                        if signals == 1 {
                            syncLog.notice("Push working over \(transport.rawValue, privacy: .public) for \(name, privacy: .public)")
                            await self?.setPushWorking(accountId, true, name: name)
                        }
                        if case .changed = signal { await self?.requestSync(accountId) }
                    }
                } catch {
                    failure = ErrorText.technical(error)
                }
                guard !Task.isCancelled else { return }
                reconnecting = true
                let seconds = (ContinuousClock.now - started).components.seconds
                syncLog.notice("Push over \(transport.rawValue, privacy: .public) ended for \(name, privacy: .public) after \(seconds)s with \(signals) signals\(failure.map { ": " + $0 } ?? "", privacy: .public)")
                if signals == 0 {
                    await self?.setPushWorking(accountId, false, name: name)
                    // Try the other transport next.
                    if transport == .webSocket {
                        transport = .eventSource
                    } else if await engine.supportsWebSocketPush() {
                        transport = .webSocket
                    }
                } else {
                    backoff = 5
                }
                await self?.requestSync(accountId)  // Catch up on anything missed while disconnected.
                try? await Task.sleep(for: .seconds(backoff))
                if signals == 0 { backoff = min(backoff * 2, 300) }
            }
        }
    }

    private func pushSignalled(_ accountId: String) { lastPushSignal[accountId] = .now }

    /// Fast polling covers an account while its push doesn't work.
    private func setPushWorking(_ accountId: String, _ working: Bool, name: String) {
        if working {
            fastPollTasks.removeValue(forKey: accountId)?.cancel()
        } else if fastPollTasks[accountId] == nil {
            syncLog.notice("Push not working for \(name, privacy: .public); checking for new mail every \(Int(self.fastPollInterval.components.seconds))s")
            fastPollTasks[accountId] = Task { [weak self, fastPollInterval] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: fastPollInterval)
                    await self?.requestSync(accountId)
                }
            }
        }
    }

    private func notLoaded(_ accountId: String) -> Error {
        JMAPError.invalidResponse("account not loaded")
    }

    private func update(_ accountId: String, failure error: Error) {
        let name = engines[accountId]?.account.name ?? gmailEngines[accountId]?.account.name ?? accountId
        syncLog.error("Sync failed for \(name, privacy: .public): \(ErrorText.technical(error), privacy: .public)")
        if error as? GoogleOAuthError == .signInExpired { return takeOffline(accountId, because: error) }
        update(accountId, .failed(ErrorText.friendly(error)), detail: ErrorText.technical(error))
    }

    /// `offline` and `needsSignIn` change those (nil keeps them: a sync that ends after Take Offline
    /// leaves the account offline).
    private func update(
        _ accountId: String, _ phase: AccountSyncStatus.Phase, success: Bool = false, detail: String? = nil,
        offline: Bool? = nil, needsSignIn: Bool? = nil
    ) {
        var status = statuses[accountId] ?? AccountSyncStatus(accountId: accountId, phase: .idle, lastSuccess: nil)
        let offline = offline ?? status.isOffline, needsSignIn = needsSignIn ?? status.needsSignIn
        // Nothing to tell when nothing shown changes (a quiet Gmail check, every 10 s while in use).
        let changed = status.phase != phase || status.errorDetail != detail || status.isOffline != offline
            || status.needsSignIn != needsSignIn
        status.phase = phase
        status.errorDetail = detail
        status.isOffline = offline
        status.needsSignIn = needsSignIn
        if success { status.lastSuccess = Date() }
        statuses[accountId] = status
        if changed { onStatus(status) }
    }
}

/// A counting semaphore for async code.
actor AsyncLimiter {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            active -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
