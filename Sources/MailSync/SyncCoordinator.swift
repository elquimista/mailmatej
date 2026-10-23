import Foundation
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
}

/// Runs sync for all accounts: a bounded number at a time, triggered by push, polling and the user.
/// Sync requests for an account that is already syncing are coalesced into one follow-up round.
public actor SyncCoordinator {
    public typealias CredentialsProvider = @Sendable (AccountRecord) throws -> Credentials

    private let store: MailStore
    private let credentials: CredentialsProvider
    /// New messages of an account, by remote id, after a sync (for rules).
    private let onArrived: @Sendable (String, [String]) -> Void
    private let onStatus: @Sendable (AccountSyncStatus) -> Void
    /// A queued change the server refused once it could be reached (its messages show the server's state).
    private let onQueuedChangeRefused: @Sendable (_ accountId: String, _ error: Error) -> Void
    private let limiter: AsyncLimiter
    private var pathMonitor: NWPathMonitor?
    private let urlSession: URLSession

    private var engines: [String: JMAPAccountSync] = [:]
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
    /// Pause between download batches of one account, to stay well under server rate limits.
    private let downloadPause: Duration = .milliseconds(500)
    private var pollTask: Task<Void, Never>?

    public init(
        store: MailStore, maxConcurrentSyncs: Int = 6, credentials: @escaping CredentialsProvider,
        onStatus: @escaping @Sendable (AccountSyncStatus) -> Void = { _ in },
        onArrived: @escaping @Sendable (_ accountId: String, _ remoteIds: [String]) -> Void = { _, _ in },
        onQueuedChangeRefused: @escaping @Sendable (_ accountId: String, _ error: Error) -> Void = { _, _ in }
    ) {
        self.store = store
        self.onQueuedChangeRefused = onQueuedChangeRefused
        self.credentials = credentials
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
                await self?.syncAll()
            }
        }
        // Back online: sync now, which first makes the changes queued meanwhile.
        pathMonitor?.cancel()
        let monitor = NWPathMonitor()
        nonisolated(unsafe) var wasSatisfied = true
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            defer { wasSatisfied = satisfied }
            guard satisfied, !wasSatisfied else { return }
            Task { await self?.syncAll() }
        }
        monitor.start(queue: DispatchQueue(label: "app.mailmatej.path"))
        pathMonitor = monitor
    }

    /// Creates engines for all enabled accounts without syncing them.
    public func loadAccounts(push: Bool) throws {
        for account in try store.accounts() where account.isEnabled && engines[account.id] == nil {
            register(account, push: push)
        }
    }

    public func stop() {
        pollTask?.cancel()
        pathMonitor?.cancel()
        for task in downloadTasks.values { task.cancel() }
        downloadTasks.removeAll()
        for task in fastPollTasks.values { task.cancel() }
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
        statuses.removeValue(forKey: id)
        pending.remove(id)
    }

    public func syncAll() {
        for id in engines.keys { requestSync(id) }
    }

    public func requestSync(_ accountId: String) {
        guard engines[accountId] != nil else { return }
        if running.contains(accountId) {
            pending.insert(accountId)
            return
        }
        running.insert(accountId)
        Task { await runSync(accountId) }
    }

    /// Runs one sync round right now (bypassing coalescing). Used by the CLI.
    public func syncNow(_ accountId: String) async throws -> JMAPAccountSync.Result {
        guard let engine = engines[accountId] else { throw JMAPError.invalidResponse("unknown account") }
        return try await engine.sync()
    }

    public func downloadBlob(accountId: String, blobId: String, type: String, name: String) async throws -> Data {
        guard let engine = engines[accountId] else { throw JMAPError.invalidResponse("account not loaded") }
        return try await engine.downloadBlob(blobId: blobId, type: type, name: name)
    }

    public func fetchBody(messageId: Int64, accountId: String) async throws -> MessageBody {
        guard let engine = engines[accountId] else { throw JMAPError.invalidResponse("account not loaded") }
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
        guard let engine = engines[accountId] else { throw JMAPError.invalidResponse("account not loaded") }
        return try await engine.ensureIdentities(addresses, name: name)
    }

    public func createMailbox(accountId: String, name: String, role: String?, parentRemoteId: String? = nil) async throws {
        guard let engine = engines[accountId] else { throw JMAPError.invalidResponse("account not loaded") }
        try await engine.createMailbox(name: name, role: role, parentRemoteId: parentRemoteId)
    }

    /// Copies a whole message into a mailbox of `accountId` (see `JMAPAccountSync.importMessage`).
    public func importMessage(
        accountId: String, _ raw: Data, mailboxRemoteId: String, keywords: [String], receivedAt: Date
    ) async throws {
        guard let engine = engines[accountId] else { throw JMAPError.invalidResponse("account not loaded") }
        try await engine.importMessage(raw, mailboxRemoteId: mailboxRemoteId, keywords: keywords, receivedAt: receivedAt)
    }

    public func restore(accountId: String, remoteIds: [String]) async throws {
        guard let engine = engines[accountId] else { throw JMAPError.invalidResponse("account not loaded") }
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

    /// Makes a change on the server now, unless older changes are still queued (it waits behind them, so
    /// changes reach the server in the order they were made) or the server can't be reached.
    private func makeOrQueue(_ change: QueuedChange, accountId: String) async throws {
        if try store.queuedChangeCount(accountId: accountId) > 0 { return try enqueue(change, accountId: accountId) }
        do {
            if let rest = try await make(change, accountId: accountId) { try enqueue(rest, accountId: accountId) }
        } catch where ErrorText.isUnreachable(error) {
            try enqueue(change, accountId: accountId)
        }
    }

    private func enqueue(_ change: QueuedChange, accountId: String) throws {
        try store.enqueueChange(accountId: accountId, try JSONEncoder().encode(change))
        syncLog.notice("Queued a change for \(accountId, privacy: .public): the server can't be reached")
        reportQueue(accountId)
    }

    /// Makes one change. Returns what's left of it when part went through and the rest couldn't (a move's
    /// delete after its copy was confirmed), so a retry doesn't copy the message twice.
    private func make(_ change: QueuedChange, accountId: String) async throws -> QueuedChange? {
        guard let engine = engines[accountId] else { throw JMAPError.invalidResponse("account not loaded") }
        switch change {
        case .update(let remoteIds, let patch):
            try await engine.update(remoteIds: remoteIds, patch: patch)
        case .destroy(let remoteIds):
            try await engine.destroy(remoteIds: remoteIds)
        case .moveAcross(let remoteId, let blobId, let targetAccountId, let mailboxRemoteId, let keywords, let receivedAt):
            guard let target = engines[targetAccountId] else { throw JMAPError.invalidResponse("account not loaded") }
            guard let raw = store.blobs.read(accountId: accountId, blobId: blobId) else {
                throw JMAPError.invalidResponse("the message isn’t stored locally")
            }
            try await target.importMessage(raw, mailboxRemoteId: mailboxRemoteId, keywords: keywords, receivedAt: receivedAt)
            requestSync(targetAccountId)
            do {
                try await engine.destroy(remoteIds: [remoteId])
            } catch where ErrorText.isUnreachable(error) {
                return .destroy(remoteIds: [remoteId])
            }
        }
        return nil
    }

    /// Makes the account's queued changes, oldest first. Throws at the first one the server still can't
    /// be reached for (the sync waits too, so it can't bring back the server's older state over local
    /// changes). One the server refuses is dropped, its messages back to the server's state, and reported.
    private func flushQueue(_ accountId: String) async throws {
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
            } catch where ErrorText.isUnreachable(error) {
                throw error
            } catch {
                syncLog.error("A queued change was refused: \(ErrorText.technical(error), privacy: .public)")
                try store.removeQueuedChange(id: item.id)
                // Back to the server's state: refused updates are fetched again by the engine; messages
                // not deleted, or not moved, come back.
                switch change {
                case .update: break
                case .destroy(let remoteIds): try? await engines[accountId]?.restore(remoteIds: remoteIds)
                case .moveAcross(let remoteId, _, _, _, _, _): try? await engines[accountId]?.restore(remoteIds: [remoteId])
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
        guard let engine = engines[accountId] else { throw JMAPError.invalidResponse("account not loaded") }
        defer { requestSync(accountId) }
        try await engine.send(message, replacingDrafts: replacingDrafts)
    }

    /// Saves a draft (see `JMAPAccountSync.saveDraft`), then syncs so it shows in Drafts.
    public func saveDraft(accountId: String, _ message: OutgoingMessage, replacing old: [String]) async throws -> String {
        guard let engine = engines[accountId] else { throw JMAPError.invalidResponse("account not loaded") }
        defer { requestSync(accountId) }
        return try await engine.saveDraft(message, replacing: old)
    }

    public func destroyDrafts(accountId: String, _ remoteIds: [String]) async throws {
        guard let engine = engines[accountId] else { throw JMAPError.invalidResponse("account not loaded") }
        try await engine.destroyDrafts(remoteIds)
    }

    public func loadDraft(accountId: String, remoteId: String) async throws -> SavedDraft {
        guard let engine = engines[accountId] else { throw JMAPError.invalidResponse("account not loaded") }
        return try await engine.loadDraft(remoteId: remoteId)
    }

    public func renameMailbox(accountId: String, remoteId: String, to name: String) async throws {
        guard let engine = engines[accountId] else { throw JMAPError.invalidResponse("account not loaded") }
        try await engine.renameMailbox(remoteId: remoteId, to: name)
    }

    public func redirect(accountId: String, remoteId: String, to recipients: [String], identityId: String, mailFrom: String) async throws {
        guard let engine = engines[accountId] else { throw JMAPError.invalidResponse("account not loaded") }
        try await engine.redirect(remoteId: remoteId, to: recipients, identityId: identityId, mailFrom: mailFrom)
    }

    public func replyHeaders(accountId: String, remoteId: String) async throws -> (inReplyTo: [String], references: [String]) {
        guard let engine = engines[accountId] else { throw JMAPError.invalidResponse("account not loaded") }
        return try await engine.replyHeaders(remoteId: remoteId)
    }

    // MARK: Private

    private func register(_ account: AccountRecord, push: Bool) {
        do {
            let engine = try JMAPAccountSync(
                account: account, credentials: try credentials(account), store: store, urlSession: urlSession)
            engines[account.id] = engine
            if push { startPush(account.id, engine: engine) }
        } catch {
            update(account.id, failure: error)
        }
    }

    private func runSync(_ accountId: String) async {
        repeat {
            pending.remove(accountId)
            guard let engine = engines[accountId] else { break }
            await limiter.acquire()
            update(accountId, .syncing)
            do {
                try await flushQueue(accountId)
                let result = try await engine.sync()
                if !result.arrived.isEmpty { onArrived(accountId, result.arrived) }
                update(accountId, .idle, success: true)
                startDownloads(accountId)
            } catch {
                update(accountId, failure: error)
            }
            await limiter.release()
        } while pending.contains(accountId)
        running.remove(accountId)
    }

    // MARK: Full download

    /// Starts downloading the account's messages that aren't stored locally yet (no-op if running).
    public func startDownloads(_ accountId: String) {
        guard downloadTasks[accountId] == nil, let engine = engines[accountId] else { return }
        downloadTasks[accountId] = Task { await downloadLoop(accountId, engine: engine) }
    }

    private func downloadLoop(_ accountId: String, engine: JMAPAccountSync) async {
        reportDownloadProgress(accountId, active: true)
        await downloadLimiter.acquire()
        var backoff = 5.0
        while !Task.isCancelled {
            do {
                reportBusyMailboxes(accountId, (try? store.mailboxIdsOfPendingDownloads(accountId: accountId, limit: 25)) ?? [])
                let result = try await engine.downloadNextBatch()
                reportDownloadProgress(accountId, active: true)
                if result.processed == 0 { break }
                backoff = 5
                try? await Task.sleep(for: downloadPause)
            } catch {
                syncLog.error("Download failed for \(engine.account.name, privacy: .public): \(ErrorText.technical(error), privacy: .public)")
                if backoff > 600 { break }  // Give up until the next sync restarts it.
                try? await Task.sleep(for: .seconds(backoff))
                backoff *= 2
            }
        }
        await downloadLimiter.release()
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
    /// broken; while push is broken the account is checked for new mail every 20 s instead.
    private func startPush(_ accountId: String, engine: JMAPAccountSync) {
        pushTasks[accountId]?.cancel()
        pushTasks[accountId] = Task { [weak self] in
            let name = engine.account.name
            var transport: JMAPAccountSync.PushTransport = await engine.supportsWebSocketPush() ? .webSocket : .eventSource
            var backoff: Double = 5
            while !Task.isCancelled {
                let started = ContinuousClock.now
                var signals = 0
                var failure: String?
                do {
                    let stream = try await engine.pushSignals(transport)
                    syncLog.notice("Push connecting over \(transport.rawValue, privacy: .public) for \(name, privacy: .public)")
                    for try await signal in stream {
                        signals += 1
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

    private func update(_ accountId: String, failure error: Error) {
        let name = engines[accountId]?.account.name ?? accountId
        syncLog.error("Sync failed for \(name, privacy: .public): \(ErrorText.technical(error), privacy: .public)")
        update(accountId, .failed(ErrorText.friendly(error)), detail: ErrorText.technical(error))
    }

    private func update(
        _ accountId: String, _ phase: AccountSyncStatus.Phase, success: Bool = false, detail: String? = nil
    ) {
        var status = statuses[accountId] ?? AccountSyncStatus(accountId: accountId, phase: .idle, lastSuccess: nil)
        status.phase = phase
        status.errorDetail = detail
        if success { status.lastSuccess = Date() }
        statuses[accountId] = status
        onStatus(status)
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
