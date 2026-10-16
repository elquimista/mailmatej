import Foundation
import JMAPKit
import MailStore
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
}

/// Runs sync for all accounts: a bounded number at a time, triggered by push, polling and the user.
/// Sync requests for an account that is already syncing are coalesced into one follow-up round.
public actor SyncCoordinator {
    public typealias CredentialsProvider = @Sendable (AccountRecord) throws -> Credentials

    private let store: MailStore
    private let credentials: CredentialsProvider
    private let onStatus: @Sendable (AccountSyncStatus) -> Void
    private let limiter: AsyncLimiter
    private let urlSession: URLSession

    private var engines: [String: JMAPAccountSync] = [:]
    private var statuses: [String: AccountSyncStatus] = [:]
    private var running: Set<String> = []
    private var pending: Set<String> = []
    private var pushTasks: [String: Task<Void, Never>] = [:]
    private var pollTask: Task<Void, Never>?

    public init(
        store: MailStore, maxConcurrentSyncs: Int = 6, credentials: @escaping CredentialsProvider,
        onStatus: @escaping @Sendable (AccountSyncStatus) -> Void = { _ in }
    ) {
        self.store = store
        self.credentials = credentials
        self.onStatus = onStatus
        self.limiter = AsyncLimiter(limit: maxConcurrentSyncs)
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        self.urlSession = URLSession(configuration: config)
    }

    /// Loads all enabled accounts, syncs them, and keeps them current with push plus a fallback poll.
    public func start(pollInterval: Duration = .seconds(300), push: Bool = true) throws {
        try loadAccounts(push: push)
        syncAll()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                await self?.syncAll()
            }
        }
    }

    /// Creates engines for all enabled accounts without syncing them.
    public func loadAccounts(push: Bool) throws {
        for account in try store.accounts() where account.isEnabled && engines[account.id] == nil {
            register(account, push: push)
        }
    }

    public func stop() {
        pollTask?.cancel()
        for task in pushTasks.values { task.cancel() }
        pushTasks.removeAll()
    }

    public func addAccount(_ account: AccountRecord) {
        register(account, push: true)
        requestSync(account.id)
    }

    public func removeAccount(id: String) {
        pushTasks.removeValue(forKey: id)?.cancel()
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

    public func fetchBody(messageId: Int64, accountId: String) async throws -> MessageBody {
        guard let engine = engines[accountId] else { throw JMAPError.invalidResponse("account not loaded") }
        return try await engine.fetchBody(messageId: messageId)
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
                try await engine.sync()
                update(accountId, .idle, success: true)
            } catch {
                update(accountId, failure: error)
            }
            await limiter.release()
        } while pending.contains(accountId)
        running.remove(accountId)
    }

    private func startPush(_ accountId: String, engine: JMAPAccountSync) {
        pushTasks[accountId]?.cancel()
        pushTasks[accountId] = Task { [weak self] in
            var backoff: Double = 5
            while !Task.isCancelled {
                do {
                    let stream = try await engine.changeNotifications()
                    backoff = 5
                    for try await _ in stream {
                        await self?.requestSync(accountId)
                    }
                } catch {
                    // Connection dropped or push unsupported; the poll keeps us current meanwhile.
                }
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 300)
                await self?.requestSync(accountId)  // Catch up on anything missed while disconnected.
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
