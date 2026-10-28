import Foundation
import GmailKit
import JMAPKit
import MailStore

/// Keeps one Gmail account in sync with the local store through the Gmail API: labels as mailboxes,
/// every message's headers, then Gmail's history of changes since the last check. There's no
/// connection to keep open: each check is a few short requests, so nothing can go stale between them.
///
/// Archive is MailMate's: the "[Gmail]/Archive" label (MailMate archives into it, and so does this
/// app), plus mail with no label at all (archived in Gmail's own apps). Each message shows where it
/// lives, so there's no All Mail mailbox: the unified All Messages shows everything.
public actor GmailAccountSync {
    public let account: AccountRecord
    private let client: GmailClient
    private let store: MailStore
    /// Labels that are mailboxes here (system ones mapped below, and the user's own).
    private var mailboxLabels: Set<String> = []
    /// The "[Gmail]/Archive" label's id, once it exists.
    private var archiveLabel: String?
    /// The user's labels' full names ("Work/Clients"), by id.
    private var labelNames: [String: String] = [:]
    /// The same, by name (lowercased): what IMAP names them by.
    private var labelIdsByName: [String: String] = [:]
    /// The labels as last stored, so a check that finds them unchanged writes nothing.
    private var storedLabels: [String]?

    public init(account: AccountRecord, tokens: GoogleTokenSource, store: MailStore, urlSession: URLSession = .shared) {
        self.account = account
        self.tokens = tokens
        self.client = GmailClient(tokens: tokens, session: urlSession)
        self.store = store
    }

    private let tokens: GoogleTokenSource
    /// The IMAP connections downloads use while they run.
    private var imapPool: [GmailIMAP] = []
    /// How many IMAP connections fetch at once: one alone is held to about 1 MB/s, and Gmail allows
    /// 15 an account (other apps' included).
    static let imapConnections = 4
    /// IMAP failed (turned off for the account, say): downloads use the API until the next sync.
    private var imapUnavailable = false
    /// When the addresses it sends as were last asked for (see `syncIdentities`).
    private var lastIdentitySync: Date?
    /// Drafts' own ids (Gmail deletes a draft by it), by their messages' ids.
    private var draftIds: [String: String] = [:]
    /// All Mail's IMAP name (it depends on the account's language).
    private var allMailName: String?
    /// When the replied and forwarded marks were last checked (see `syncFlags`), and whether the Inbox
    /// watch has seen a change since.
    private var lastFlagCheck: Date?
    private var flagsDue = true
    /// The connection the flag work uses (see `withAllMail`), and its turns.
    private var allMail: GmailIMAP?
    private let allMailTurn = AsyncLimiter(limit: 1)

    /// The headers stored for every message.
    static let headerNames = ["From", "Sender", "To", "Cc", "Bcc", "Reply-To", "Subject", "Date", "Message-ID", "In-Reply-To", "References"]
    /// The Archive mailbox (a local id: it stands for the archive label and unlabelled mail).
    static let archive = "ARCHIVE"
    /// MailMate's archive label, which this app archives into too.
    static let archiveLabelName = "[Gmail]/Archive"
    /// Gmail's system labels that are mailboxes (and Archive): name, role and place in the account.
    static let systemMailboxes: [String: (name: String, role: String, order: Int)] = [
        "INBOX": ("Inbox", "inbox", 0), "DRAFT": ("Drafts", "drafts", 1), "SENT": ("Sent Mail", "sent", 2),
        archive: ("Archive", "archive", 3), "SPAM": ("Spam", "junk", 4), "TRASH": ("Trash", "trash", 5),
    ]
    /// Bumped when how labels map to mailboxes changes: accounts synced before are fetched again.
    static let mappingVersion = "2"
    static let mappingState = "GmailMapping"
    static let historyState = "GmailHistory"
    /// Where an unfinished first (or repeated) full sync started in Gmail's history.
    static let fullSyncState = "GmailFullStart"
    /// Set while a full sync fetches every message again (not only those not stored yet), and how many
    /// it has done, so one interrupted by quitting carries on where it was.
    static let refetchState = "GmailRefetch"
    static let refetchDoneState = "GmailRefetchDone"

    // MARK: Sync

    /// One round: labels, then the changes since the last round (everything, the first time).
    /// `progress` hears how many message headers a full sync has downloaded, and of how many; `arrived`
    /// of new mail as it's stored (not a full sync's): what rules run on.
    @discardableResult
    public func sync(
        progress: @escaping @Sendable (_ downloaded: Int, _ total: Int) async -> Void = { _, _ in },
        arrived: @escaping @Sendable (_ remoteIds: [String]) async -> Void = { _ in }
    ) async throws -> JMAPAccountSync.Result {
        var result = JMAPAccountSync.Result()
        imapUnavailable = false  // try IMAP again
        result.mailboxes = try await syncLabels()
        if lastIdentitySync.map({ Date().timeIntervalSince($0) > 600 }) ?? true {
            do {
                _ = try await syncIdentities()
            } catch {
                syncLog.error("Gmail send-as addresses for \(self.account.name, privacy: .public): \(ErrorText.technical(error), privacy: .public)")
            }
        }
        // An account synced when mailboxes meant something else (or before that was recorded) has every
        // message fetched again. A first sync still under way records nothing yet: it just carries on.
        let mapping = try store.syncState(accountId: account.id, type: Self.mappingState)
        let synced = try store.syncState(accountId: account.id, type: Self.historyState) != nil
        let refetching = try store.syncState(accountId: account.id, type: Self.refetchState) != nil
        if !refetching, mapping.map({ $0 != Self.mappingVersion }) ?? synced { try startRefetch() }
        if try store.syncState(accountId: account.id, type: Self.refetchState) != nil {
            try await fullSync(refetchKnown: true, into: &result, progress: progress)
        } else if let since = try store.syncState(accountId: account.id, type: Self.historyState) {
            do {
                try await syncHistory(since: since, into: &result, arrived: arrived)
            } catch GmailClient.GmailError.historyExpired {
                // Too long since the last check: list everything again, refreshing the messages known.
                try startRefetch()
                try await fullSync(refetchKnown: true, into: &result, progress: progress)
            }
        } else {
            try await fullSync(refetchKnown: false, into: &result, progress: progress)
        }
        // Only after changes: a quiet check writes nothing (with many accounts checked every minute,
        // writes would keep refreshing the lists).
        if result.created + result.updated + result.destroyed > 0 || result.mailboxes > 0 {
            try store.recountMailboxes(accountId: account.id)
        }
        // The replied and forwarded marks, which only IMAP has: when the Inbox watch saw a change, else
        // every few minutes; not while a full sync is under way (its messages aren't all stored yet).
        if try store.syncState(accountId: account.id, type: Self.historyState) != nil,
            try store.syncState(accountId: account.id, type: Self.refetchState) == nil,
            flagsDue || lastFlagCheck.map({ Date().timeIntervalSince($0) > Self.flagCheckInterval }) ?? true
        {
            do {
                try await syncFlags()
            } catch {
                syncLog.error("Gmail flags for \(self.account.name, privacy: .public): \(ErrorText.technical(error), privacy: .public)")
            }
            lastFlagCheck = Date()
            flagsDue = false
        }
        return result
    }

    private func syncLabels() async throws -> Int {
        let labels = try await client.labels()
        let counts = try store.mailboxCounts(accountId: account.id)
        let user = labels.filter { $0.type == "user" }
        archiveLabel = user.first { $0.name.caseInsensitiveCompare(Self.archiveLabelName) == .orderedSame }?.id
        labelNames = Dictionary(user.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        labelIdsByName = Dictionary(user.map { ($0.name.lowercased(), $0.id) }, uniquingKeysWith: { a, _ in a })
        let byName = Dictionary(user.map { ($0.name, $0.id) }, uniquingKeysWith: { a, _ in a })
        var mailboxes: [IncomingMailbox] = []
        func add(_ id: String, name: String, parent: String?, role: String?, order: Int) {
            let count = counts[id]
            mailboxes.append(IncomingMailbox(
                remoteId: id, parentRemoteId: parent, name: name, role: role, sortOrder: order,
                totalEmails: count?.total ?? 0, unreadEmails: count?.unread ?? 0))
        }
        for (id, box) in Self.systemMailboxes { add(id, name: box.name, parent: nil, role: box.role, order: box.order) }
        // The user's labels, nested by "/" as Gmail shows them: "Work/Clients" inside "Work".
        for label in user where label.id != archiveLabel {  // the archive label is the Archive mailbox
            var parent: String?
            var name = label.name
            if let slash = label.name.lastIndex(of: "/"), let parentId = byName[String(label.name[..<slash])] {
                parent = parentId
                name = String(label.name[label.name.index(after: slash)...])
            }
            add(label.id, name: name, parent: parent, role: nil, order: 10)
        }
        mailboxLabels = Set(mailboxes.map(\.remoteId))
        let signature = mailboxes.map { "\($0.remoteId)|\($0.parentRemoteId ?? "")|\($0.name)" }.sorted()
        guard signature != storedLabels else { return 0 }  // 0: nothing changed
        try store.applyMailboxes(accountId: account.id, upserts: mailboxes, destroyed: [], replaceAll: true)
        storedLabels = signature
        return mailboxes.count
    }

    /// Marks the account for fetching every message again (see `refetchState`), from where Gmail's
    /// history stands now.
    private func startRefetch() throws {
        try store.setSyncState("1", accountId: account.id, type: Self.refetchState)
        try store.setSyncState(nil, accountId: account.id, type: Self.refetchDoneState)
        try store.setSyncState(nil, accountId: account.id, type: Self.historyState)
        try store.setSyncState(nil, accountId: account.id, type: Self.fullSyncState)
    }

    /// Lists every message (newest first) and stores the ones not known yet; with `refetchKnown`, all
    /// of them. Resumes where an interrupted one stopped: messages already stored are skipped (when
    /// fetching all again, those it had done, less a margin: new mail moves the list down), and
    /// Gmail's history from where it started then catches up on what changed meanwhile.
    private func fullSync(
        refetchKnown: Bool, into result: inout JMAPAccountSync.Result, progress: @Sendable (Int, Int) async -> Void
    ) async throws {
        // The account's size, for the progress bar, and (unless resuming) where history stands.
        let profile = try await client.profile()
        let total = profile.messagesTotal ?? 0
        let start: String
        if let started = try store.syncState(accountId: account.id, type: Self.fullSyncState) {
            start = started
        } else {
            guard let current = profile.historyId else { throw GmailClient.APIError(status: 0, message: "no history id") }
            start = current
            try store.setSyncState(start, accountId: account.id, type: Self.fullSyncState)
        }
        // Over IMAP when it can (whole messages at the network's speed, not 95 a minute); what it got
        // stays if it stops, and the API carries on from there.
        let listed: Set<String>
        do {
            listed = try await imapList(refetchKnown: refetchKnown, into: &result, progress: progress)
        } catch {
            syncLog.notice("Gmail IMAP unavailable for \(self.account.name, privacy: .public), using the API: \(ErrorText.technical(error), privacy: .public)")
            listed = try await apiList(refetchKnown: refetchKnown, total: total, into: &result, progress: progress)
        }
        let gone = try store.remoteIDs(accountId: account.id).subtracting(listed)
        if !gone.isEmpty {
            try store.deleteMessages(accountId: account.id, remoteIds: Array(gone))
            result.destroyed += gone.count
        }
        // Done: from now on, Gmail's history (and the mailboxes as they're mapped now).
        try store.setSyncState(start, accountId: account.id, type: Self.historyState)
        try store.setSyncState(Self.mappingVersion, accountId: account.id, type: Self.mappingState)
        for state in [Self.fullSyncState, Self.refetchState, Self.refetchDoneState] {
            try store.setSyncState(nil, accountId: account.id, type: state)
        }
        var catchUp = JMAPAccountSync.Result()
        try await syncHistory(since: start, into: &catchUp)
        result.updated += catchUp.updated
        result.destroyed += catchUp.destroyed
    }

    /// The full sync's listing through the API: every message whole, 95 a minute (Gmail's quota).
    /// Returns every message's id.
    private func apiList(
        refetchKnown: Bool, total: Int, into result: inout JMAPAccountSync.Result, progress: @Sendable (Int, Int) async -> Void
    ) async throws -> Set<String> {
        let known = refetchKnown ? [] : try store.remoteIDs(accountId: account.id)
        var skip = refetchKnown ? max(0, (Int(try store.syncState(accountId: account.id, type: Self.refetchDoneState) ?? "") ?? 0) - 50) : 0
        var listed = Set<String>()
        var read = 0
        var token: String?
        await progress(0, total)
        repeat {
            let page = try await client.listMessages(pageToken: token)
            token = page.next
            let ids = page.messages.map(\.id)
            listed.formUnion(ids)
            let done = min(skip, ids.count)
            skip -= done
            let todo = ids.dropFirst(done).filter { !known.contains($0) }
            read += ids.count - todo.count  // already done before quitting
            // In chunks, so the list fills in as it goes (and quitting loses at most one's work). Each
            // message comes whole, so it's listed, searchable and downloaded at once; when fetching
            // everything again, those stored here need only their labels.
            for chunk in todo.chunked(25) {
                let (refreshed, _) = try await refresh(chunk.filter { refetchKnown && store.blobs.contains(accountId: account.id, blobId: $0) })
                let rest = chunk.filter { !refreshed.contains($0) }
                let (whole, _) = try await fetch(rest, format: .raw)
                result.created += refreshed.count + (try storeWhole(whole))
                read += chunk.count
                if refetchKnown { try store.setSyncState(String(read), accountId: account.id, type: Self.refetchDoneState) }
                await progress(read, max(total, read))
            }
            if todo.isEmpty { await progress(read, max(total, read)) }
            try recountIfDue()
        } while token != nil
        return listed
    }

    /// The full sync's listing over IMAP: All Mail, Spam and Trash indexed, then the messages not stored
    /// yet fetched whole in batches, newest first, with their labels and flags (when fetching all again,
    /// those stored here get only their labels). Returns every message's id.
    private func imapList(
        refetchKnown: Bool, into result: inout JMAPAccountSync.Result, progress: @Sendable (Int, Int) async -> Void
    ) async throws -> Set<String> {
        let pool = try await connectIMAP(Self.imapConnections)
        let imap = pool[0]
        do {
            let (folders, entries) = try await index(imap)
            let known = try store.remoteIDs(accountId: account.id)
            var done = 0
            await progress(0, entries.count)
            for folder in [folders.all, folders.spam, folders.trash].compactMap({ $0 }) {
                let here = entries.filter { $0.folder == folder }.sorted { $0.uid > $1.uid }  // newest first
                guard !here.isEmpty else { continue }
                try await imap.examine(folder)
                let stored = { (id: String) in self.store.blobs.contains(accountId: self.account.id, blobId: id) }
                let relabel = refetchKnown ? here.filter { known.contains($0.id) && stored($0.id) } : []
                let whole = here.filter { !known.contains($0.id) || (refetchKnown && !stored($0.id)) }
                done += here.count - relabel.count - whole.count  // already here
                for chunk in relabel.chunked(500) {
                    let fetched = try await imap.fetch(chunk.map(\.uid), bodies: false)
                    var incoming: [IncomingMessage] = []
                    for message in fetched {
                        guard let data = store.blobs.read(accountId: account.id, blobId: message.gmailId),
                            let updated = Self.incoming(
                                gmailMessage(message, folder: folder, folders: folders), raw: MIMEPart.parse(data),
                                mailboxLabels: mailboxLabels, archiveLabel: archiveLabel)
                        else { continue }
                        incoming.append(updated)
                    }
                    try upsert(incoming)
                    result.updated += incoming.count
                    done += chunk.count
                    await progress(done, entries.count)
                }
                // Whole messages, up to 50 or about 4 MB a batch, several batches at once.
                var created = 0
                let batches = Self.batches(whole, size: \.size, maxCount: 50, maxBytes: 4_000_000)
                try await fetchWhole(batches.map { $0.map(\.uid) }, in: folder, over: pool) { batch, fetched in
                    created += try self.storeWhole(fetched.compactMap { message in
                        message.raw.map { (self.gmailMessage(message, folder: folder, folders: folders), $0) }
                    })
                    done += batch.count
                    await progress(done, entries.count)
                    try self.recountIfDue()
                }
                result.created += created
            }
            await progress(entries.count, entries.count)
            for connection in pool { await connection.close() }
            return Set(entries.map(\.id))
        } catch {
            for connection in pool { await connection.close() }
            throw error
        }
    }

    /// All Mail, Spam and Trash indexed: each message's folder, UID, Gmail id and size.
    private func index(_ imap: GmailIMAP) async throws -> (GmailIMAP.Folders, [(folder: String, uid: UInt32, id: String, size: Int)]) {
        let folders = try await imap.folders()
        guard let all = folders.all else { throw GmailIMAP.IMAPError.malformed("no All Mail") }
        var entries: [(folder: String, uid: UInt32, id: String, size: Int)] = []
        for folder in [all, folders.spam, folders.trash].compactMap({ $0 }) {
            try await imap.examine(folder)
            entries += try await imap.index().map { (folder, $0.uid, $0.gmailId, $0.size) }
        }
        return (folders, entries)
    }

    /// An IMAP message as the API would give it: its labels by the API's ids (IMAP names the system
    /// ones "\\Inbox" and so on, and the user's by name), Spam and Trash by its folder, Unread and
    /// Starred by its flags.
    private func gmailMessage(_ message: GmailIMAP.Message, folder: String, folders: GmailIMAP.Folders) -> GmailClient.Message {
        var labels = Set(message.labels.compactMap { label -> String? in
            switch label.lowercased() {
            case "\\inbox": "INBOX"
            case "\\sent": "SENT"
            case "\\draft": "DRAFT"
            case "\\starred": "STARRED"
            case "\\important": "IMPORTANT"
            case "\\spam": "SPAM"
            case "\\trash": "TRASH"
            default: labelIdsByName[label.lowercased()]
            }
        })
        if folder == folders.spam { labels.insert("SPAM") }
        if folder == folders.trash { labels.insert("TRASH") }
        if !message.flags.contains(where: { $0.caseInsensitiveCompare("\\Seen") == .orderedSame }) { labels.insert("UNREAD") }
        if message.flags.contains(where: { $0.caseInsensitiveCompare("\\Flagged") == .orderedSame }) { labels.insert("STARRED") }
        return GmailClient.Message(
            id: message.gmailId, threadId: message.threadId, labelIds: Array(labels), receivedAt: message.internalDate,
            sizeEstimate: message.size ?? message.raw?.count)
    }

    /// Splits messages into batches of at most `maxCount`, and about `maxBytes` (at least one each).
    typealias IndexEntry = (folder: String, uid: UInt32, id: String, size: Int)

    static func batches<Item>(_ items: [Item], size: (Item) -> Int, maxCount: Int, maxBytes: Int) -> [[Item]] {
        var batches: [[Item]] = []
        var current: [Item] = []
        var bytes = 0
        for item in items {
            if !current.isEmpty, current.count >= maxCount || bytes + size(item) > maxBytes {
                batches.append(current)
                current = []
                bytes = 0
            }
            current.append(item)
            bytes += size(item)
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    /// Applies Gmail's history since `since`: new and changed messages are fetched again, deleted ones
    /// removed. New ones are what rules run on: each is told to `arrived` once it's stored.
    private func syncHistory(
        since: String, into result: inout JMAPAccountSync.Result, arrived: (@Sendable ([String]) async -> Void)? = nil
    ) async throws {
        var token: String?
        var added: [String] = []
        var changed = Set<String>()
        var deleted = Set<String>()
        /// Each message's label changes, in order.
        var relabeled: [String: [LabelChange]] = [:]
        var latest: String?
        repeat {
            let page = try await client.history(since: since, pageToken: token)
            for record in page.history ?? [] {
                for change in record.messagesAdded ?? [] {
                    added.append(change.message.id)
                    changed.insert(change.message.id)
                    deleted.remove(change.message.id)
                }
                for change in record.messagesDeleted ?? [] {
                    deleted.insert(change.message.id)
                    changed.remove(change.message.id)
                }
                for (changes, isAdded) in [(record.labelsAdded ?? [], true), (record.labelsRemoved ?? [], false)] {
                    for change in changes where !deleted.contains(change.message.id) {
                        changed.insert(change.message.id)
                        relabeled[change.message.id, default: []].append(LabelChange(added: isAdded, labels: change.labelIds ?? []))
                    }
                }
            }
            latest = page.historyId ?? latest
            token = page.nextPageToken
        } while token != nil

        #if DEBUG
            if ProcessInfo.processInfo.environment["MMJ_DEBUG_GMAIL"] != nil {
                NSLog("MMJ gmail history since \(since): \(changed.count) changed, \(deleted.count) deleted, now \(latest ?? "-")")
            }
        #endif
        let known = try store.remoteIDs(accountId: account.id)
        if !changed.isEmpty {
            // New mail comes whole. Mail stored here whose labels changed (read, flagged, moved) changes
            // here as the history says, without fetching it again (a request and 5 quota units each:
            // marking thousands read used to hold up new mail for minutes). What that can't tell, and
            // mail added again, gets its labels from Gmail, with its headers from the copy here, or else
            // from Gmail too (its body follows with the downloads).
            let newlyAdded = Set(added)
            let applied = try applyLabelChanges(
                relabeled.filter { known.contains($0.key) && !newlyAdded.contains($0.key) && changed.contains($0.key) })
            result.updated += applied.count
            let changed = Array(changed.subtracting(applied))
            let new = changed.filter { !known.contains($0) }
            let (refreshed, gone) = try await refresh(changed.filter { known.contains($0) && store.blobs.contains(accountId: account.id, blobId: $0) })
            let headersOnly = changed.filter { known.contains($0) && !refreshed.contains($0) && !gone.contains($0) }
            let (metadata, missingMetadata) = try await fetch(headersOnly, format: .metadata)
            let messages = metadata.compactMap(incoming)
            try upsert(messages)
            let (stored, missingWhole) = try await arrive(new, rulesFor: newlyAdded, arrived: arrived)
            deleted.formUnion(gone + missingMetadata + missingWhole)
            result.updated += refreshed.count + messages.count + stored
        }
        let gone = deleted.intersection(known)
        if !gone.isEmpty {
            try store.deleteMessages(accountId: account.id, remoteIds: Array(gone))
            result.destroyed += gone.count
        }
        if let latest, latest != since { try store.setSyncState(latest, accountId: account.id, type: Self.historyState) }
    }

    /// More new messages than this at once come over IMAP, at the network's speed: through the API each
    /// costs 60 quota units, about 1.6 messages a second once the first ten are in (a minute for 100).
    static let imapArrivals = 20

    /// Stores new messages whole, each as it comes (over IMAP in small batches when there are many), so
    /// the first don't wait for the last, nor for a big one; those in `rulesFor` (Gmail's history says they
    /// arrived) are told to `arrived` once stored. Returns how many were stored, and the ids Gmail no
    /// longer has.
    private func arrive(
        _ ids: [String], rulesFor added: Set<String>, arrived: (@Sendable ([String]) async -> Void)?
    ) async throws -> (stored: Int, missing: [String]) {
        arrival = Arrival()
        lastRecount = .now  // the sync recounts once it's done: one new message needs no more
        // Many over IMAP: found in All Mail, Spam and Trash by their ids, fetched whole in small batches
        // over several connections. Any it doesn't find are left to the API.
        if ids.count > Self.imapArrivals, !imapUnavailable {
            var pool: [GmailIMAP] = []
            do {
                pool = try await connectIMAP(Self.imapConnections)
                let (folders, entries) = try await locate(ids, on: pool[0])
                for folder in [folders.all, folders.spam, folders.trash].compactMap({ $0 }) {
                    let here = entries.filter { $0.folder == folder }.sorted { $0.uid > $1.uid }  // newest first
                    let batches = Self.batches(here, size: \.size, maxCount: 10, maxBytes: 1_000_000)
                    try await fetchWhole(batches.map { $0.map(\.uid) }, in: folder, over: pool) { _, fetched in
                        try await self.keep(fetched.compactMap { message in
                            message.raw.map { (self.gmailMessage(message, folder: folder, folders: folders), $0) }
                        }, rulesFor: added, arrived: arrived)
                    }
                }
            } catch {
                syncLog.notice("Gmail IMAP unavailable for \(self.account.name, privacy: .public)'s new mail, using the API: \(ErrorText.technical(error), privacy: .public)")
                imapUnavailable = true
            }
            for connection in pool { await connection.close() }
        }
        // The rest (all of them, usually) through the API.
        let client = self.client
        let rest = ids.filter { !arrival.kept.contains($0) }
        try await concurrently(rest, limit: 4, { id in try await client.message(id, format: .raw) }) { id, message in
            guard let message else { return self.arrival.missing.append(id) }
            guard let raw = message.raw.flatMap(Data.init(base64URL:)) else { return }
            try await self.keep([(message, raw)], rulesFor: added, arrived: arrived)
        }
        return (arrival.stored, arrival.missing)
    }

    /// What `arrive` has done so far.
    private struct Arrival {
        var stored = 0
        var kept = Set<String>()
        var missing: [String] = []
    }

    private var arrival = Arrival()

    /// Stores new messages that came (see `arrive`).
    private func keep(
        _ messages: [(message: GmailClient.Message, raw: Data)], rulesFor added: Set<String>,
        arrived: (@Sendable ([String]) async -> Void)?
    ) async throws {
        arrival.stored += try storeWhole(messages)
        arrival.kept.formUnion(messages.map(\.message.id))
        try recountIfDue()  // the mailboxes' counts along with them
        let new = messages.map(\.message.id).filter(added.contains)
        if !new.isEmpty { await arrived?(new) }
    }

    /// Recounts the account's mailboxes (their badges) while many messages are being stored, at most
    /// every second: a recount reads the whole account, and each refreshes the lists.
    private func recountIfDue() throws {
        guard lastRecount.map({ $0.duration(to: .now) >= .seconds(1) }) ?? true else { return }
        try store.recountMailboxes(accountId: account.id)
        lastRecount = .now
    }

    private var lastRecount: ContinuousClock.Instant?

    /// Where these messages are over IMAP, found by their Gmail ids: in All Mail, or else in Spam or Trash
    /// (their folders, UIDs and sizes); those Gmail doesn't have are left out. Only they are looked up:
    /// listing an old account's every message (hundreds of thousands) for a few took seconds, and
    /// keeping that list took memory for as long as the app ran.
    private func locate(_ ids: [String], on imap: GmailIMAP) async throws -> (GmailIMAP.Folders, [IndexEntry]) {
        #if DEBUG
            let started = Date()
            defer {
                if ProcessInfo.processInfo.environment["MMJ_DEBUG_GMAIL"] != nil {
                    NSLog("MMJ imap located \(ids.count) messages by id in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
                }
            }
        #endif
        let folders = try await imap.folders()
        var left = Set(ids)
        var found: [IndexEntry] = []
        for folder in [folders.all, folders.spam, folders.trash].compactMap({ $0 }) where !left.isEmpty {
            try await imap.examine(folder)
            let here = try await imap.index(uids: try await search(Array(left), on: imap)).filter { left.contains($0.gmailId) }
            found += here.map { (folder, $0.uid, $0.gmailId, $0.size) }
            left.subtract(here.map(\.gmailId))
        }
        return (folders, found)
    }

    /// UIDs of the open mailbox's messages with these Gmail ids.
    private func search(_ ids: [String], on imap: GmailIMAP) async throws -> [UInt32] {
        var uids: [UInt32] = []
        for criteria in Self.idSearches(ids) { uids += try await imap.search(criteria) }
        return uids
    }

    /// The IMAP searches for messages by their Gmail ids (X-GM-MSGID, the ids in decimal), 50 at a time:
    /// Gmail takes 100 in one search, but can't parse 150.
    static func idSearches(_ ids: [String], each: Int = 50) -> [String] {
        ids.compactMap { UInt64($0, radix: 16) }.chunked(each).map { anyOf($0.map { "X-GM-MSGID \($0)" }) }
    }

    /// A label change in Gmail's history: labels added to a message, or taken off it.
    struct LabelChange: Equatable {
        var added: Bool
        var labels: [String]
    }

    /// A stored message's marks and mailboxes (by remote id), as the store has them.
    typealias Marks = (keywords: Set<String>, mailboxes: Set<String>)

    /// Applies label changes to the messages stored here; returns those it applied (see `applying`).
    private func applyLabelChanges(_ changes: [String: [LabelChange]]) throws -> Set<String> {
        guard !changes.isEmpty else { return [] }
        let stored = try store.keywordsAndMailboxes(accountId: account.id, remoteIds: Array(changes.keys))
        var updated: [String: Marks] = [:]
        for (id, list) in changes {
            guard let marks = stored[id],
                let after = Self.applying(list, to: marks, mailboxLabels: mailboxLabels, archiveLabel: archiveLabel)
            else { continue }
            updated[id] = after
        }
        try store.setKeywordsAndMailboxes(accountId: account.id, updated, among: Self.labelKeywords)
        return Set(updated.keys)
    }

    /// The keywords Gmail keeps as labels: UNREAD (the absence of $seen), STARRED and DRAFT.
    static let labelKeywords: Set<String> = ["$seen", "$flagged", "$draft"]

    /// A message's marks and mailboxes after label changes, in order, as `incoming` has them from its
    /// labels: read, flagged and draft from UNREAD, STARRED and DRAFT; a mailbox per label shown as one;
    /// Archive by the archive label, or when no other mailbox is left. Labels not shown here (IMPORTANT,
    /// categories) change nothing. nil when it can't be told from the changes: a message in Archive
    /// given a mailbox, in an account whose Archive is also a label (does it have that label? Gmail knows).
    static func applying(
        _ changes: [LabelChange], to marks: Marks, mailboxLabels: Set<String>, archiveLabel: String?
    ) -> Marks? {
        var (keywords, mailboxes) = marks
        for change in changes {
            for label in change.labels {
                let keyword = ["UNREAD": "$seen", "STARRED": "$flagged", "DRAFT": "$draft"][label]
                if let keyword {
                    // UNREAD is the absence of $seen.
                    if change.added == (label != "UNREAD") { keywords.insert(keyword) } else { keywords.remove(keyword) }
                }
                if label == archiveLabel {
                    if change.added { mailboxes.insert(archive) } else { mailboxes.remove(archive) }
                } else if mailboxLabels.contains(label), label != archive {
                    if change.added {
                        if archiveLabel != nil, mailboxes.contains(archive) { return nil }
                        mailboxes.insert(label)
                    } else {
                        mailboxes.remove(label)
                    }
                }
            }
            if mailboxes.subtracting([archive]).isEmpty {
                mailboxes.insert(archive)
            } else if archiveLabel == nil {
                mailboxes.remove(archive)
            }
        }
        return (keywords, mailboxes)
    }

    /// Messages in a format, a few requests at a time (they're paced under Gmail's quota, see
    /// `GmailClient`; whole ones fewer at once, they're bigger); `missing` are the ones that no longer exist.
    private func fetch(_ ids: [String], format: GmailClient.Format) async throws -> (found: [GmailClient.Message], missing: [String]) {
        guard !ids.isEmpty else { return ([], []) }
        let client = self.client
        let results = try await concurrently(ids, limit: format == .raw ? 4 : 8) { id in
            try await client.message(id, format: format, headers: format == .metadata ? Self.headerNames : [])
        }
        var found: [GmailClient.Message] = []
        var missing: [String] = []
        for (id, message) in zip(ids, results) {
            if let message { found.append(message) } else { missing.append(id) }
        }
        return (found, missing)
    }

    /// Stores whole messages (format raw): each from its own headers and Gmail's labels, with its raw
    /// copy, body and parts, so it's downloaded as it's listed. Returns how many were stored.
    private func storeWhole(_ messages: [GmailClient.Message]) throws -> Int {
        try storeWhole(messages.compactMap { message in message.raw.flatMap(Data.init(base64URL:)).map { (message, $0) } })
    }

    /// Stores messages with their raw copies (from the API or IMAP): each from its own headers and its
    /// labels, with its body and parts, so it's downloaded as it's listed. A message without Gmail's
    /// snippet (IMAP has none) gets one from its text. Returns how many were stored.
    private func storeWhole(_ messages: [(message: GmailClient.Message, raw: Data)]) throws -> Int {
        var incoming: [IncomingMessage] = []
        var copies: [(id: String, data: Data, body: MessageBody, parts: [MessagePart])] = []
        for (original, data) in messages {
            let mime = MIMEPart.parse(data)
            let structure = BodyStructure(mime)
            let (body, parts) = structure.render(blobId: original.id)
            var message = original
            if message.snippet == nil { message.snippet = Self.preview(body.text ?? "") }
            guard
                let stored = Self.incoming(
                    message, headers: mime.headers, hasAttachment: structure.hasAttachment, mailboxLabels: mailboxLabels,
                    archiveLabel: archiveLabel)
            else { continue }
            incoming.append(stored)
            copies.append((message.id, data, body, parts))
        }
        try upsert(incoming)
        let ids = try store.messageIDsByRemoteID(accountId: account.id, remoteIds: copies.map(\.id))
        for copy in copies {
            guard let id = ids[copy.id] else { continue }
            try store.blobs.write(copy.data, accountId: account.id, blobId: copy.id)  // a Gmail message's blob id is its id
            try store.saveBody(messageId: id, copy.body, parts: copy.parts)
        }
        try store.setDownloadState(1, messageIds: Array(ids.values))
        return incoming.count
    }

    /// A list's preview line from a message's text, as Gmail's snippet is: its words with a space
    /// between, the first 200 characters. Only as much of the text as that takes is read.
    static func preview(_ text: String) -> String {
        var line = ""
        var letters = 0  // other than spaces (a space and a zero-width character after it make one)
        var space = false
        for character in text {
            if character.isWhitespace {
                space = !line.isEmpty
                continue
            }
            if space { line.append(" ") }
            space = false
            line.append(character)
            letters += 1
            if letters == 200 { break }
        }
        return String(line.prefix(200))
    }

    /// Messages stored here with a raw copy, updated with their labels as Gmail has them now (the
    /// cheapest request) and their headers from the copy. Returns those updated, and those gone.
    private func refresh(_ ids: [String]) async throws -> (updated: [String], gone: [String]) {
        let (found, missing) = try await fetch(ids, format: .minimal)
        var incoming: [IncomingMessage] = []
        for message in found {
            guard let data = store.blobs.read(accountId: account.id, blobId: message.id),
                let stored = Self.incoming(message, raw: MIMEPart.parse(data), mailboxLabels: mailboxLabels, archiveLabel: archiveLabel)
            else { continue }
            incoming.append(stored)
        }
        try upsert(incoming)
        return (incoming.map(\.remoteId), missing)
    }

    // MARK: Watching

    /// Watches the Inbox over IMAP IDLE and calls `onChange` whenever the server announces something
    /// there (new mail, archiving, read or unread), so changes made elsewhere (Gmail on the web, a
    /// phone) show within seconds, until cancelled. The IDLE is renewed every 4 minutes, and a renewal
    /// that isn't answered counts as a dead connection: it reconnects, waiting longer after each failure
    /// (5 s to 5 minutes), unless Google no longer takes the sign-in. It's only a signal: the minute's
    /// check still covers everything else.
    public nonisolated func watch(onChange: @escaping @Sendable () -> Void) async {
        var backoff = 5.0
        while !Task.isCancelled {
            let imap = GmailIMAP(email: account.username, tokens: tokens)
            var signInExpired = false
            do {
                try await imap.connect()
                try await imap.examine("INBOX")
                backoff = 5
                // A change (or catching up on what happened while not watching) may be in flags too.
                let signal: @Sendable () -> Void = {
                    #if DEBUG
                        if ProcessInfo.processInfo.environment["MMJ_DEBUG_GMAIL"] != nil { NSLog("MMJ gmail idle: change announced") }
                    #endif
                    Task {
                        await self.flagsMayHaveChanged()
                        onChange()
                    }
                }
                signal()
                while !Task.isCancelled { try await imap.idle(for: .seconds(240), onChange: signal) }
            } catch {
                syncLog.notice("Gmail watch for \(self.account.name, privacy: .public) stopped: \(ErrorText.technical(error), privacy: .public)")
                signInExpired = error as? GoogleOAuthError == .signInExpired
                #if DEBUG
                    if ProcessInfo.processInfo.environment["MMJ_DEBUG_GMAIL"] != nil { NSLog("MMJ gmail idle: stopped: \(error)") }
                #endif
            }
            await imap.close()
            // Only signing in again helps, and that starts a new watch (see `SyncCoordinator.takeOnline`).
            guard !Task.isCancelled, !signInExpired else { return }
            try? await Task.sleep(for: .seconds(backoff))
            backoff = min(backoff * 2, 300)
        }
    }

    // MARK: Changes

    /// Makes a change the app describes as JMAP does (see `JMAPAccountSync.update`) with Gmail's labels:
    /// `keywords/$seen` and `$flagged` are the Unread and Starred labels, `$answered` and `$forwarded` IMAP
    /// flags (see `imapKeywords`); a message's new set of
    /// mailboxes (`mailboxIds`) adds their labels and takes off the other mailboxes' (moving, as into a
    /// folder: Sent and Drafts stay); `mailboxIds/<id>` adds or takes off one. Archive is MailMate's
    /// "[Gmail]/Archive" label, made the first time it's needed.
    public func update(remoteIds: [String], patch: [String: JSONValue]) async throws {
        guard !remoteIds.isEmpty else { return }
        var add = Set<String>(), remove = Set<String>()
        var flagsOn = Set<String>(), flagsOff = Set<String>()
        func set(_ label: String, _ on: Bool) {
            if on { add.insert(label); remove.remove(label) } else { remove.insert(label); add.remove(label) }
        }
        for (key, value) in patch {
            let on = value.boolValue == true
            switch key {
            case "keywords/$seen": set("UNREAD", !on)
            case "keywords/$flagged": set("STARRED", on)
            case "mailboxIds":
                let targets = Set((value.objectValue ?? [:]).filter { $0.value.boolValue == true }.keys)
                // Off every mailbox label but the targets', then onto the targets.
                for box in mailboxLabels.union([Self.archive]) where !targets.contains(box) && box != "SENT" && box != "DRAFT" {
                    if box == Self.archive {
                        if let archiveLabel { set(archiveLabel, false) }
                    } else {
                        set(box, false)
                    }
                }
                for box in targets { set(try await label(for: box), true) }
            case _ where key.hasPrefix("mailboxIds/"):
                let box = String(key.dropFirst("mailboxIds/".count))
                if on {
                    set(try await label(for: box), true)
                } else if box != Self.archive || archiveLabel != nil {
                    set(box == Self.archive ? archiveLabel! : box, false)
                }
            case _ where key.hasPrefix("keywords/"):
                // Replied and forwarded are IMAP flags; other keywords (tags, $junk) have no Gmail equivalent.
                guard let flag = Self.imapKeywords[String(key.dropFirst("keywords/".count))] else { break }
                if on { flagsOn.insert(flag); flagsOff.remove(flag) } else { flagsOff.insert(flag); flagsOn.remove(flag) }
            default:
                break
            }
        }
        if !add.isEmpty || !remove.isEmpty {
            do {
                try await client.modify(remoteIds, add: Array(add), remove: Array(remove))
            } catch let error as GmailClient.APIError where error.status == 400 || error.status == 404 {
                try? await restore(remoteIds: remoteIds)  // back to Gmail's state
                throw JMAPAccountSync.ChangeRefused(count: remoteIds.count, deleting: false, reason: error.message)
            }
        }
        if !flagsOn.isEmpty || !flagsOff.isEmpty { try await storeFlags(remoteIds, on: flagsOn, off: flagsOff) }
    }

    /// The label behind a mailbox: Archive's is "[Gmail]/Archive", made now if the account has none.
    private func label(for mailbox: String) async throws -> String {
        guard mailbox == Self.archive else { return mailbox }
        if let archiveLabel { return archiveLabel }
        let made = try await client.createLabel(Self.archiveLabelName)
        archiveLabel = made.id
        labelNames[made.id] = made.name
        return made.id
    }

    /// Deletes messages for good.
    public func destroy(remoteIds: [String]) async throws {
        guard !remoteIds.isEmpty else { return }
        try await client.delete(remoteIds)
    }

    /// Fetches messages again (a change that didn't go through: back to Gmail's state).
    public func restore(remoteIds: [String]) async throws {
        let (refreshed, gone) = try await refresh(remoteIds.filter { store.blobs.contains(accountId: account.id, blobId: $0) })
        let (found, missing) = try await fetch(remoteIds.filter { !refreshed.contains($0) && !gone.contains($0) }, format: .metadata)
        try upsert(found.compactMap(incoming))
        if !(missing + gone).isEmpty { try store.deleteMessages(accountId: account.id, remoteIds: missing + gone) }
    }

    /// Makes a label (inside `parentRemoteId`'s, "Parent/Name"); Archive's role makes MailMate's archive label.
    public func createMailbox(name: String, role: String?, parentRemoteId: String? = nil) async throws {
        if role == "archive" {
            _ = try await label(for: Self.archive)
        } else {
            let parent = parentRemoteId.flatMap { labelNames[$0] }
            _ = try await client.createLabel(parent.map { "\($0)/\(name)" } ?? name)
        }
        storedLabels = nil  // so the new label is stored
        _ = try await syncLabels()
    }

    /// Renames a label, keeping it where it is ("Work/Old" becomes "Work/New").
    public func renameMailbox(remoteId: String, to name: String) async throws {
        guard let full = labelNames[remoteId] else { throw GmailClient.APIError(status: 400, message: "Gmail’s own mailboxes can’t be renamed") }
        let parent = full.range(of: "/", options: .backwards).map { String(full[..<$0.lowerBound]) }
        try await client.renameLabel(remoteId, to: parent.map { "\($0)/\(name)" } ?? name)
        storedLabels = nil
        _ = try await syncLabels()
    }

    /// Copies a whole message into this account (a move from another account), into `mailboxRemoteId`
    /// with its read and flag state.
    public func importMessage(_ raw: Data, mailboxRemoteId: String, keywords: [String], receivedAt: Date) async throws {
        var labels = [try await label(for: mailboxRemoteId)]
        let lowered = Set(keywords.map { $0.lowercased() })
        if !lowered.contains("$seen") { labels.append("UNREAD") }
        if lowered.contains("$flagged") { labels.append("STARRED") }
        try await client.importMessage(raw, labels: labels)
    }

    // MARK: Messages

    /// A Gmail message as the store keeps it; nil for a chat.
    func incoming(_ message: GmailClient.Message) -> IncomingMessage? {
        Self.incoming(message, mailboxLabels: mailboxLabels, archiveLabel: archiveLabel)
    }

    /// A message with only Gmail's metadata (labels and the headers asked for).
    /// `mailboxLabels`: the labels shown as mailboxes; `archiveLabel`: "[Gmail]/Archive"'s id.
    static func incoming(_ message: GmailClient.Message, mailboxLabels: Set<String>, archiveLabel: String? = nil) -> IncomingMessage? {
        let payload = message.payload
        let type = MailHeaders.value(of: payload?.header("Content-Type")) ?? payload?.mimeType?.lowercased() ?? ""
        return incoming(
            message, headers: { payload?.headers($0) ?? [] },
            // From the headers alone: mixed content (or a single non-text part) is what carries attachments.
            hasAttachment: type == "multipart/mixed" || (!type.hasPrefix("text/") && !type.hasPrefix("multipart/") && !type.isEmpty),
            mailboxLabels: mailboxLabels, archiveLabel: archiveLabel)
    }

    /// A message from its raw copy (headers and parts) and Gmail's labels.
    static func incoming(
        _ message: GmailClient.Message, raw: MIMEPart, mailboxLabels: Set<String>, archiveLabel: String? = nil
    ) -> IncomingMessage? {
        incoming(
            message, headers: raw.headers, hasAttachment: BodyStructure(raw).hasAttachment, mailboxLabels: mailboxLabels,
            archiveLabel: archiveLabel)
    }

    /// `headers` gives every value of a header (unfolded, encoded words and all).
    static func incoming(
        _ message: GmailClient.Message, headers: (String) -> [String], hasAttachment: Bool, mailboxLabels: Set<String>,
        archiveLabel: String?
    ) -> IncomingMessage? {
        let labels = Set(message.labelIds ?? [])
        guard !labels.contains("CHAT") else { return nil }
        var mailboxes = labels.intersection(mailboxLabels).subtracting([Self.archive])
        // Archive: the archive label, or no mailbox at all (archived in Gmail's apps).
        if archiveLabel.map(labels.contains) == true || mailboxes.isEmpty { mailboxes.insert(Self.archive) }
        var keywords: [String] = []
        if !labels.contains("UNREAD") { keywords.append("$seen") }
        if labels.contains("STARRED") { keywords.append("$flagged") }
        if labels.contains("DRAFT") { keywords.append("$draft") }

        func header(_ name: String) -> String? { headers(name).first }
        var addresses: [IncomingMessage.Address] = []
        func add(_ role: AddressRole, _ header: String, groups groupRole: AddressRole? = nil) {
            for value in headers(header) {
                let parsed = MailHeaders.addresses(value)
                for address in parsed.addresses { addresses.append(.init(role: role, name: address.name, email: address.email)) }
                if let groupRole {
                    for name in parsed.emptyGroups { addresses.append(.init(role: groupRole, name: name, email: "")) }
                }
            }
        }
        add(.from, "From")
        add(.sender, "Sender")
        add(.to, "To", groups: .toGroup)
        add(.cc, "Cc", groups: .ccGroup)
        add(.bcc, "Bcc")
        add(.replyTo, "Reply-To")

        let dateHeader = header("Date")
        let sentAt = MailHeaders.date(dateHeader)
        return IncomingMessage(
            remoteId: message.id, threadId: message.threadId ?? message.id, blobId: message.id,
            mailboxRemoteIds: Array(mailboxes), keywords: keywords, size: message.sizeEstimate ?? 0,
            receivedAt: message.receivedAt ?? sentAt ?? Date(), sentAt: sentAt,
            messageIdHeader: MailHeaders.messageIds(header("Message-ID")).first,
            inReplyTo: MailHeaders.messageIds(header("In-Reply-To")).first,
            subject: MailHeaders.decodeWords(header("Subject") ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            preview: MailHeaders.decodeEntities(message.snippet ?? ""), hasAttachment: hasAttachment,
            addresses: addresses, references: MailHeaders.messageIds(header("References")),
            sentZone: sentAt == nil ? nil : JMAPAccountSync.zone(ofDateHeader: dateHeader) ?? 0)
    }

    // MARK: Bodies and downloads

    /// Fetches and stores one message (when it's opened before it's downloaded): only the raw message
    /// is fetched (Gmail charges a third as much as for the parsed one and its attachments); its body
    /// and parts come from taking it apart here.
    public func fetchBody(messageId: Int64) async throws -> MessageBody {
        guard let detail = try store.detail(id: messageId) else { throw GmailClient.APIError(status: 404, message: "unknown message") }
        let raw = try await rawMessage(detail.remoteId, blobId: detail.blobId)
        let (body, parts) = BodyStructure.render(raw: raw, blobId: detail.blobId)
        try store.saveBody(messageId: messageId, body, parts: parts)
        try store.setDownloadState(1, messageIds: [messageId])
        return body
    }

    /// Downloads the next messages not stored locally yet, newest first: the raw message, and the body
    /// and parts taken from it. Over IMAP when it can (at the network's speed); through the API, whose
    /// quota allows about 95 a minute per account, for what IMAP can't (or when it's unavailable).
    public func downloadNextBatch(limit: Int = 50) async throws -> JMAPAccountSync.DownloadBatchResult {
        var pending = try store.pendingDownloads(accountId: account.id, limit: imapUnavailable ? limit : 1000)
        guard !pending.isEmpty else {
            await closeIMAP()  // done: no connection left open
            return .init(processed: 0, failed: 0)
        }
        var done: [Int64] = []
        if !imapUnavailable {
            do {
                done = try await imapDownload(pending)
            } catch {
                syncLog.notice("Gmail IMAP downloads unavailable for \(self.account.name, privacy: .public), using the API: \(ErrorText.technical(error), privacy: .public)")
                imapUnavailable = true
                await closeIMAP()
            }
            try store.setDownloadState(1, messageIds: done)
            // What IMAP didn't have goes through the API (a few at a time, it's slow).
            pending = Array(pending.filter { !done.contains($0.id) }.prefix(limit))
            if pending.isEmpty { return .init(processed: done.count, failed: 0) }
        }
        let accountId = account.id
        let store = self.store
        let client = self.client
        let outcomes = try await concurrently(pending, limit: 8) { item -> Bool in
            var raw = store.blobs.read(accountId: accountId, blobId: item.blobId)
            if raw == nil {
                guard let data = try await client.message(item.remoteId, format: .raw)?.raw.flatMap(Data.init(base64URL:)) else {
                    return false
                }
                try store.blobs.write(data, accountId: accountId, blobId: item.blobId)
                raw = data
            }
            if !item.hasBody, let raw {
                let (body, parts) = BodyStructure.render(raw: raw, blobId: item.blobId)
                try store.saveBody(messageId: item.id, body, parts: parts)
            }
            return true
        }
        let failed = zip(pending, outcomes).filter { !$0.1 }.map(\.0.id)
        try store.setDownloadState(1, messageIds: zip(pending, outcomes).filter(\.1).map(\.0.id))
        try store.setDownloadState(2, messageIds: failed)
        return .init(processed: done.count + pending.count, failed: failed.count)
    }

    /// Downloads messages over IMAP (the connections stay open while downloads go on): finds them by
    /// their ids, fetches them whole by folder in batches, and stores their copies, bodies and parts.
    /// Returns those downloaded (the others Gmail doesn't have over IMAP).
    private func imapDownload(_ pending: [MailStore.PendingDownload]) async throws -> [Int64] {
        let pool = try await openIMAP()
        let (_, found) = try await locate(pending.map(\.remoteId), on: pool[0])
        let places = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var located: [String: [(item: MailStore.PendingDownload, uid: UInt32)]] = [:]
        for item in pending {
            if let place = places[item.remoteId] { located[place.folder, default: []].append((item, place.uid)) }
        }
        var done: [Int64] = []
        #if DEBUG
            let started = Date()
            var bytes = 0
            defer {
                if ProcessInfo.processInfo.environment["MMJ_DEBUG_GMAIL"] != nil {
                    let seconds = Date().timeIntervalSince(started)
                    NSLog("MMJ imap downloads: \(done.count) messages, \(bytes / 1024) KB in \(String(format: "%.2f", seconds)) s over \(pool.count) connections (\(String(format: "%.1f", Double(bytes) / 1_048_576 / max(seconds, 0.001))) MB/s)")
                }
            }
        #endif
        for (folder, items) in located {
            let byUID = Dictionary(items.map { ($0.uid, $0.item) }, uniquingKeysWith: { a, _ in a })
            let batches = Self.batches(items, size: \.item.size, maxCount: 50, maxBytes: 4_000_000).map { $0.map(\.uid) }
            try await fetchWhole(batches, in: folder, over: pool) { _, fetched in
                var stored: [Int64] = []
                for message in fetched {
                    guard let item = byUID[message.uid], let data = message.raw else { continue }
                    try self.store.blobs.write(data, accountId: self.account.id, blobId: item.blobId)
                    #if DEBUG
                        bytes += data.count
                    #endif
                    if !item.hasBody {
                        let (body, parts) = BodyStructure.render(raw: data, blobId: item.blobId)
                        try self.store.saveBody(messageId: item.id, body, parts: parts)
                    }
                    stored.append(item.id)
                }
                // Marked as each batch arrives, so the progress moves along with it.
                try self.store.setDownloadState(1, messageIds: stored)
                done += stored
            }
        }
        return done
    }

    /// Fetches batches of a folder's messages whole over several connections at once, each connection
    /// taking the next batch when it's done, and hands each batch (its UIDs and messages) to `handle`
    /// as it arrives.
    private func fetchWhole(
        _ batches: [[UInt32]], in folder: String, over connections: [GmailIMAP],
        handle: ([UInt32], [GmailIMAP.Message]) async throws -> Void
    ) async throws {
        guard !batches.isEmpty else { return }
        for imap in connections { try await imap.examine(folder) }
        try await withThrowingTaskGroup(of: (Int, [UInt32], [GmailIMAP.Message]).self) { group in
            var free = Array(connections.indices)
            var next = 0
            func start(on connection: Int) {
                let imap = connections[connection], uids = batches[next]
                next += 1
                group.addTask { (connection, uids, try await imap.fetch(uids, bodies: true)) }
            }
            while next < batches.count, let connection = free.popLast() { start(on: connection) }
            while let (connection, uids, messages) = try await group.next() {
                try await handle(uids, messages)
                if next < batches.count { start(on: connection) }
            }
        }
    }

    /// Signs in `count` IMAP connections at once (those that manage it; at least one, or it throws).
    private func connectIMAP(_ count: Int) async throws -> [GmailIMAP] {
        let email = account.username, tokens = self.tokens
        let results = await withTaskGroup(of: Result<GmailIMAP, Error>.self) { group in
            for _ in 0..<count {
                group.addTask {
                    let imap = GmailIMAP(email: email, tokens: tokens)
                    do {
                        try await imap.connect()
                        return .success(imap)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            return await group.reduce(into: [Result<GmailIMAP, Error>]()) { $0.append($1) }
        }
        let connected = results.compactMap { try? $0.get() }
        guard !connected.isEmpty else {
            if case .failure(let error)? = results.first { throw error }
            throw GmailIMAP.IMAPError.closed
        }
        return connected
    }

    /// The download connections, signed in when first needed (kept while downloads go on).
    private func openIMAP() async throws -> [GmailIMAP] {
        if imapPool.isEmpty {
            var count = Self.imapConnections
            #if DEBUG
                count = Int(ProcessInfo.processInfo.environment["MMJ_IMAP_CONNECTIONS"] ?? "") ?? count
            #endif
            imapPool = try await connectIMAP(count)
        }
        return imapPool
    }

    private func closeIMAP() async {
        for connection in imapPool { await connection.close() }
        imapPool = []
    }

    /// One part's data (an embedded picture or an attachment), by the id its part is stored with,
    /// "<message blob id>.<part id>", from the message stored here; a bare id is the whole raw message.
    public func downloadBlob(blobId: String, type: String, name: String) async throws -> Data {
        guard let dot = blobId.firstIndex(of: ".") else { return try await rawMessage(blobId, blobId: blobId) }
        let messageBlob = String(blobId[..<dot]), partId = String(blobId[blobId.index(after: dot)...])
        let raw = try await rawMessage(messageBlob, blobId: messageBlob)  // a Gmail message's blob id is its id
        guard let part = MIMEPart.parse(raw).find(partId) else {
            throw GmailClient.APIError(status: 404, message: "the attachment isn’t in the message")
        }
        return part.content
    }

    /// The raw message, from the local copy, else fetched from Gmail and kept.
    private func rawMessage(_ remoteId: String, blobId: String) async throws -> Data {
        if let stored = store.blobs.read(accountId: account.id, blobId: blobId) { return stored }
        guard let data = try await client.message(remoteId, format: .raw)?.raw.flatMap(Data.init(base64URL:)) else {
            throw GmailClient.APIError(status: 404, message: "the message no longer exists in Gmail")
        }
        try store.blobs.write(data, accountId: account.id, blobId: blobId)
        return data
    }
}

// MARK: - IMAP flags

extension GmailAccountSync {
    /// The marks Gmail's API has nothing for, kept as IMAP flags as MailMate keeps them: the keyword
    /// here, the flag there.
    static let imapKeywords = ["$answered": "\\Answered", "$forwarded": "$Forwarded"]
    /// Where the flag check left off in All Mail: "UIDVALIDITY HIGHESTMODSEQ".
    static let flagsState = "GmailFlags"
    /// How often the flags are checked when the Inbox watch announces nothing (changes elsewhere).
    static let flagCheckInterval: TimeInterval = 300

    func flagsMayHaveChanged() { flagsDue = true }

    #if DEBUG
        /// A flag check now; `fromScratch` as the first one is (every flagged message's).
        public func debugCheckFlags(fromScratch: Bool) async throws {
            if fromScratch { try store.setSyncState(nil, accountId: account.id, type: Self.flagsState) }
            try await syncFlags()
        }

        /// A message's IMAP flags in All Mail, all of them, as Gmail has them.
        public func debugIMAPFlags(remoteId: String) async throws -> [Set<String>] {
            try await withAllMail { imap, _ in
                guard let id = UInt64(remoteId, radix: 16) else { return [] }
                return try await imap.flags(try await imap.search("X-GM-MSGID \(id)")).map(\.flags)
            }
        }

        /// Sets or clears an IMAP flag on a message as another app would (not through the store).
        public func debugStoreFlag(remoteId: String, flag: String, add: Bool) async throws {
            try await storeFlags([remoteId], on: add ? [flag] : [], off: add ? [] : [flag])
        }
    #endif

    /// Stores messages from Gmail's labels, keeping the marks only IMAP has (the API can't tell them, so
    /// they stay as the flag check or this app left them).
    func upsert(_ messages: [IncomingMessage]) throws {
        guard !messages.isEmpty else { return }
        let kept = try store.keywords(accountId: account.id, remoteIds: messages.map(\.remoteId), among: Set(Self.imapKeywords.keys))
        try store.upsertMessages(accountId: account.id, messages.map { message in
            guard let marks = kept[message.remoteId] else { return message }
            var message = message
            message.keywords = Array(Set(message.keywords).union(marks))
            return message
        })
    }

    /// Sets and clears IMAP flags on messages, found in All Mail by their Gmail ids (one in Spam or Trash
    /// isn't there, and its marks don't matter). A lost connection counts as Gmail out of reach, so the
    /// change waits in the queue.
    func storeFlags(_ remoteIds: [String], on: Set<String>, off: Set<String>) async throws {
        do {
            try await withAllMail { imap, _ in
                let uids = try await self.search(remoteIds, on: imap)
                try await imap.store(uids, flags: Array(on), add: true)
                try await imap.store(uids, flags: Array(off), add: false)
            }
        } catch GmailIMAP.IMAPError.closed {
            throw URLError(.networkConnectionLost)
        }
    }

    /// Brings the replied and forwarded marks in line with Gmail's IMAP flags, which its history doesn't
    /// report: the first time, every flagged message's (and others' go); then those changed since
    /// (CONDSTORE's CHANGEDSINCE).
    func syncFlags() async throws {
        let left = try store.syncState(accountId: account.id, type: Self.flagsState)?.split(separator: " ").compactMap { UInt64($0) }
        let state = try await withAllMail { imap, opened -> String? in
            guard let validity = opened.uidValidity, let modseq = opened.highestModSeq else { return nil }
            if let left, left.count == 2, left[0] == UInt64(validity) {
                guard modseq > left[1] else { return nil }
                try self.applyFlags(try await imap.flags(nil, changedSince: left[1]), all: false)
            } else {
                let flagged = try await imap.search(Self.anyOf(Self.imapKeywords.values.sorted().map(Self.searchKey)))
                try self.applyFlags(try await imap.flags(flagged), all: true)
            }
            return "\(validity) \(modseq)"
        }
        if let state { try store.setSyncState(state, accountId: account.id, type: Self.flagsState) }
    }

    /// Stores what IMAP says of messages' flags as their marks (`all`: these are every flagged message, so
    /// the others' marks go). Only what changes is written.
    private func applyFlags(_ fetched: [(gmailId: String, flags: Set<String>)], all: Bool) throws {
        let current = try store.keywords(
            accountId: account.id, remoteIds: all ? nil : fetched.map(\.gmailId), among: Set(Self.imapKeywords.keys))
        var wanted: [String: Set<String>] = [:]
        for (id, flags) in fetched {
            let lowered = Set(flags.map { $0.lowercased() })
            wanted[id] = Set(Self.imapKeywords.filter { lowered.contains($0.value.lowercased()) }.map(\.key))
        }
        var on: [String: [String]] = [:], off: [String: [String]] = [:]
        for id in Set(wanted.keys).union(current.keys) {
            let want = wanted[id] ?? [], have = current[id] ?? []
            for keyword in want.subtracting(have) { on[keyword, default: []].append(id) }
            for keyword in have.subtracting(want) { off[keyword, default: []].append(id) }
        }
        let ids = try store.messageIDsByRemoteID(
            accountId: account.id, remoteIds: Array(Set(on.values.joined()).union(off.values.joined())))
        for (keyword, remoteIds) in on { try store.setKeyword(keyword, true, messageIds: remoteIds.compactMap { ids[$0] }) }
        for (keyword, remoteIds) in off { try store.setKeyword(keyword, false, messageIds: remoteIds.compactMap { ids[$0] }) }
    }

    /// Runs `work` with All Mail open (read-write, CONDSTORE) on the connection kept for it: signing in
    /// anew took half a second, for every change Gmail announced. One use at a time. A connection Gmail
    /// closed since is replaced, and the work done again (setting flags and reading them can be).
    private func withAllMail<T: Sendable>(_ work: (GmailIMAP, GmailIMAP.Opened) async throws -> T) async throws -> T {
        await allMailTurn.acquire()
        do {
            let result = try await onAllMail(work)
            await allMailTurn.release()
            return result
        } catch {
            await allMailTurn.release()
            throw error
        }
    }

    private func onAllMail<T: Sendable>(_ work: (GmailIMAP, GmailIMAP.Opened) async throws -> T) async throws -> T {
        if let kept = allMail {
            do {
                return try await work(kept, try await openAllMail(kept))
            } catch {
                allMail = nil  // dropped, or in a state not worth knowing: a new one
                await kept.close()
            }
        }
        let imap = GmailIMAP(email: account.username, tokens: tokens)
        do {
            try await imap.connect()
            let result = try await work(imap, try await openAllMail(imap))
            allMail = imap
            return result
        } catch {
            await imap.close()
            throw error
        }
    }

    /// Selects All Mail (anew each use, for its UIDVALIDITY and HIGHESTMODSEQ now).
    private func openAllMail(_ imap: GmailIMAP) async throws -> GmailIMAP.Opened {
        if allMailName == nil { allMailName = try await imap.folders().all }
        guard let allMail = allMailName else { throw GmailIMAP.IMAPError.malformed("no All Mail") }
        return try await imap.open(allMail, readOnly: false)
    }

    /// IMAP search criteria matching any of these: "OR a OR b c".
    static func anyOf(_ criteria: [String]) -> String {
        criteria.dropLast().reversed().reduce(criteria.last ?? "ALL") { "OR \($1) \($0)" }
    }

    /// The search for messages with a flag: "ANSWERED" for \Answered, "KEYWORD $Forwarded".
    static func searchKey(_ flag: String) -> String {
        flag.hasPrefix("\\") ? String(flag.dropFirst()).uppercased() : "KEYWORD " + flag
    }
}

// MARK: - Sending

extension GmailAccountSync {
    #if DEBUG
        /// The messages of the account's drafts, as Gmail lists them.
        public func debugDraftMessageIds() async throws -> [String] { try await client.drafts().map(\.message.id) }
    #endif

    /// Stores the addresses the account sends as (Gmail settings › Accounts › Send mail as: its own, and
    /// the aliases verified there) as its identities, and returns them (lowercased).
    @discardableResult
    func syncIdentities() async throws -> Set<String> {
        let addresses = try await client.sendAs().filter { $0.isPrimary == true || $0.verificationStatus == "accepted" }
        try store.replaceIdentities(accountId: account.id, addresses.map { address in
            let email = address.sendAsEmail.lowercased()
            return (remoteId: email, name: address.displayName ?? "", email: email)
        })
        lastIdentitySync = Date()
        return Set(addresses.map { $0.sendAsEmail.lowercased() })
    }

    /// See `JMAPAccountSync.ensureIdentities`. Gmail sends only as the account's own address and the
    /// aliases verified in its settings, so it refuses the others (sent from the account's own address).
    public func ensureIdentities(_ addresses: [String], name: String) async throws -> [(email: String, reason: String)] {
        let known = try await syncIdentities()
        return addresses.map { $0.lowercased() }.filter { !known.contains($0) }.map {
            ($0, "Gmail sends only as addresses added in its settings, under Accounts › Send mail as.")
        }
    }

    /// Sends a message (see `JMAPAccountSync.send`): written out whole and handed to Gmail, which takes
    /// the recipients from its headers (Bcc included, left out of what it delivers), files it in Sent and
    /// puts it in the conversation it replies to. The drafts it was written in go once it's sent.
    public func send(_ message: OutgoingMessage, replacingDrafts: [String] = []) async throws {
        let raw = OutgoingMIME.message(message, attachments: try await outgoingAttachments(message), bcc: true)
        _ = try await client.sendMessage(raw, threadId: try await threadId(of: message))
        do {
            try await destroyDrafts(replacingDrafts)
        } catch {
            syncLog.error("Sent, but its drafts stay: \(ErrorText.technical(error), privacy: .public)")
        }
    }

    /// Saves a message as a draft (see `JMAPAccountSync.saveDraft`), then removes the drafts it replaces.
    /// Returns the new draft's message id.
    public func saveDraft(_ message: OutgoingMessage, replacing old: [String]) async throws -> String {
        let raw = OutgoingMIME.message(message, attachments: try await outgoingAttachments(message), bcc: true, asDraft: true)
        let draft = try await client.createDraft(raw, threadId: try await threadId(of: message))
        draftIds[draft.message.id] = draft.id
        do {
            try await destroyDrafts(old)
        } catch {
            syncLog.error("Saved, but the drafts it replaces stay: \(ErrorText.technical(error), privacy: .public)")
        }
        return draft.message.id
    }

    /// Deletes drafts for good, by their messages' ids (a draft's own id, which Gmail deletes it by, is
    /// looked up when it wasn't saved here). A message that's no longer a draft (sent since) stays.
    public func destroyDrafts(_ remoteIds: [String]) async throws {
        guard !remoteIds.isEmpty else { return }
        if remoteIds.contains(where: { draftIds[$0] == nil }) {
            for draft in try await client.drafts() { draftIds[draft.message.id] = draft.id }
        }
        var gone: [String] = []
        for id in remoteIds {
            guard let draftId = draftIds[id] else { continue }
            do {
                try await client.deleteDraft(draftId)
            } catch let error as GmailClient.APIError where error.status == 404 {
                // deleted already
            }
            draftIds[id] = nil
            gone.append(id)
        }
        try store.deleteMessages(accountId: account.id, remoteIds: gone)
    }

    /// A draft as written (see `JMAPAccountSync.loadDraft`), taken from its raw message.
    public func loadDraft(remoteId: String) async throws -> SavedDraft {
        let data = try await rawMessage(remoteId, blobId: remoteId)  // a Gmail message's blob id is its id
        let raw = MIMEPart.parse(data)
        func addresses(_ name: String) -> [EmailAddress] {
            raw.headers(name).flatMap { MailHeaders.addresses($0).addresses }.map { EmailAddress(name: $0.name, email: $0.email) }
        }
        let (body, parts) = BodyStructure(raw).render(blobId: remoteId)
        var draft = SavedDraft()
        draft.from = addresses("From").first?.email?.lowercased()
        draft.to = addresses("To")
        draft.cc = addresses("Cc")
        draft.bcc = addresses("Bcc")
        draft.replyTo = addresses("Reply-To")
        draft.subject = MailHeaders.decodeWords(raw.header("Subject") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        draft.text = (body.text ?? body.html.map(JMAPAccountSync.plainText(fromHTML:)) ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")  // as written, not as sent
        draft.isMarkdown = raw.header(JMAPAccountSync.draftFormatHeader)?.trimmingCharacters(in: .whitespaces).lowercased() == "markdown"
        draft.inReplyTo = MailHeaders.messageIds(raw.header("In-Reply-To"))
        draft.references = MailHeaders.messageIds(raw.header("References"))
        draft.attachments = parts
        return draft
    }

    /// Redirects a message as it is (a rule's Redirect) to `recipients`: over Gmail's SMTP, since the API
    /// only sends to the addresses in a message. Resent- headers on top say who sent it on, to whom and
    /// when (RFC 5322 §3.6.6); the rest is untouched. Gmail puts the account's address in a From it
    /// can't send as (keeping the name), as it does for MailMate's redirects through it.
    public func redirect(remoteId: String, to recipients: [String], mailFrom: String) async throws {
        let raw = try await rawMessage(remoteId, blobId: remoteId)  // a Gmail message's blob id is its id
        let domain = mailFrom.split(separator: "@").last.map(String.init) ?? "mailmatej.local"
        let resent = [
            "Resent-From: " + mailFrom,
            "Resent-Date: " + OutgoingMIME.dateText(Date()),
            "Resent-Message-ID: <\(UUID().uuidString)@\(domain)>",
            OutgoingMIME.addressHeader("Resent-To", recipients.map { EmailAddress(name: nil, email: $0) }),
        ].joined(separator: "\r\n") + "\r\n"
        try await GmailSMTP(email: account.username, tokens: tokens).send(Data(resent.utf8) + raw, from: mailFrom, to: recipients)
    }

    /// In-Reply-To and References for a reply to this message (see `Compose.references`), from its
    /// raw message.
    public func replyHeaders(remoteId: String) async throws -> (inReplyTo: [String], references: [String]) {
        let raw = MIMEPart.parse(try await rawMessage(remoteId, blobId: remoteId))
        let messageId = MailHeaders.messageIds(raw.header("Message-ID"))
        guard !messageId.isEmpty else { return ([], []) }
        return (messageId, Compose.references(
            messageId: messageId, references: raw.header("References").map(MailHeaders.messageIds),
            inReplyTo: raw.header("In-Reply-To").map(MailHeaders.messageIds)))
    }

    /// The Gmail conversation a reply belongs to: that of the message it replies to (stored here, else
    /// found in Gmail by its Message-ID). Gmail only threads a sent reply given it.
    private func threadId(of message: OutgoingMessage) async throws -> String? {
        guard let parent = message.inReplyTo.first ?? message.references.last else { return nil }
        if let stored = try store.threadId(accountId: account.id, messageIdHeader: parent) { return stored }
        return try await client.message(rfc822MessageId: parent)?.threadId
    }

    /// What's attached, with its bytes: parts of the account's messages (Forward, or a reopened draft's),
    /// and files.
    private func outgoingAttachments(_ message: OutgoingMessage) async throws -> [OutgoingMIME.Attachment] {
        var attachments: [OutgoingMIME.Attachment] = []
        for part in message.attachments {
            let data = try await downloadBlob(blobId: part.blobId, type: part.type, name: part.name ?? "")
            attachments.append(OutgoingMIME.Attachment(name: part.name, type: part.type, data: data, cid: part.cid))
        }
        return attachments + message.files.map { OutgoingMIME.Attachment(name: $0.name, type: $0.type, data: $0.data, cid: $0.cid) }
    }
}

/// A message's parts sorted as RFC 8621 §4.1.4 does (`parseStructure`): what shows as the text body,
/// what as the HTML body, and what are attachments.
struct BodyStructure {
    struct Leaf {
        let part: MIMEPart
        let type: String
        let disposition: String?
        let name: String?
        let cid: String?
        let charset: String?

        init(_ part: MIMEPart) {
            self.part = part
            let contentType = part.header("Content-Type")
            type = part.type
            let dispositionHeader = part.header("Content-Disposition")
            disposition = MailHeaders.value(of: dispositionHeader)
            name = MailHeaders.parameter("filename", in: dispositionHeader) ?? MailHeaders.parameter("name", in: contentType)
                ?? (part.type == "message/rfc822" ? "message.eml" : nil)
            cid = part.header("Content-ID").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) }
            charset = MailHeaders.parameter("charset", in: contentType)
        }

        var isInlineMedia: Bool { type.hasPrefix("image/") || type.hasPrefix("audio/") || type.hasPrefix("video/") }

        /// The content as text, in its charset.
        var text: String { MailHeaders.text(part.content, charset: charset) }
    }

    private(set) var textBody: [Leaf] = []
    private(set) var htmlBody: [Leaf] = []
    private(set) var attachments: [Leaf] = []

    init(_ root: MIMEPart) {
        parse([root], multipartType: "mixed", inAlternative: false, text: true, html: true)
    }

    private mutating func parse(_ parts: [MIMEPart], multipartType: String, inAlternative: Bool, text: Bool, html: Bool) {
        var text = text, html = html
        let textLength = text ? textBody.count : -1
        let htmlLength = html ? htmlBody.count : -1
        for (i, part) in parts.enumerated() {
            let type = part.type
            if type.hasPrefix("multipart/"), !part.children.isEmpty {
                let sub = String(type.dropFirst("multipart/".count))
                parse(part.children, multipartType: sub, inAlternative: inAlternative || sub == "alternative", text: text, html: html)
                continue
            }
            let leaf = Leaf(part)
            let isInline = leaf.disposition != "attachment"
                && (leaf.type == "text/plain" || leaf.type == "text/html" || leaf.isInlineMedia)
                && (i == 0 || (multipartType != "related" && (leaf.isInlineMedia || leaf.name == nil)))
            guard isInline else {
                attachments.append(leaf)
                continue
            }
            if multipartType == "alternative" {
                switch leaf.type {
                case "text/plain": textBody.append(leaf)
                case "text/html": htmlBody.append(leaf)
                default: attachments.append(leaf)
                }
                continue
            } else if inAlternative {
                if leaf.type == "text/plain" { html = false }
                if leaf.type == "text/html" { text = false }
            }
            if text { textBody.append(leaf) }
            if html { htmlBody.append(leaf) }
            if (!text || !html) && leaf.isInlineMedia { attachments.append(leaf) }
        }
        if multipartType == "alternative", text, html {
            if textLength == textBody.count, htmlLength != htmlBody.count { textBody += htmlBody[htmlLength...] }
            if htmlLength == htmlBody.count, textLength != textBody.count { htmlBody += textBody[textLength...] }
        }
    }

    /// Whether a message has attachments: parts other than pictures its HTML shows.
    var hasAttachment: Bool { attachments.contains { $0.cid == nil || $0.disposition == "attachment" } }

    /// The body to show and search, and the parts to keep (as JMAP's: embedded media from the HTML body
    /// and every attachment, named or not), their blob ids "<message blob id>.<part id>".
    static func render(raw: Data, blobId: String) -> (MessageBody, [MessagePart]) { BodyStructure(MIMEPart.parse(raw)).render(blobId: blobId) }

    func render(blobId: String) -> (MessageBody, [MessagePart]) {
        // A part in both bodies (an HTML-only message's HTML) is decoded once.
        var decoded: [String: String] = [:]
        func decode(_ leaf: Leaf) -> String {
            if let text = decoded[leaf.part.partId] { return text }
            let text = leaf.text
            decoded[leaf.part.partId] = text
            return text
        }
        let text = textBody.filter { $0.type.hasPrefix("text/") }.map { leaf in
            leaf.type == "text/html" ? JMAPAccountSync.plainText(fromHTML: decode(leaf)) : decode(leaf)
        }.joined(separator: "\n\n")
        var html: String?
        if htmlBody.contains(where: { $0.type == "text/html" }) {
            html = htmlBody.filter { $0.type.hasPrefix("text/") }.map { leaf in
                leaf.type == "text/html" ? decode(leaf) : "<pre style=\"white-space: pre-wrap\">" + JMAPAccountSync.escapeHTML(decode(leaf)) + "</pre>"
            }.joined()
        }
        var seen = Set<String>()
        let embedded = htmlBody.filter { $0.cid != nil && !$0.type.hasPrefix("text/") }
        let parts = (embedded + attachments).compactMap { leaf -> MessagePart? in
            guard seen.insert(leaf.part.partId).inserted else { return nil }
            return MessagePart(
                blobId: "\(blobId).\(leaf.part.partId)", cid: leaf.cid, type: leaf.type, name: leaf.name, size: leaf.part.contentSize)
        }
        return (MessageBody(html: html, text: text), parts)
    }
}

/// Runs `work` on each item, at most `limit` at a time, returning the results in the items' order.
func concurrently<Item: Sendable, Output: Sendable>(
    _ items: [Item], limit: Int, _ work: @escaping @Sendable (Item) async throws -> Output
) async throws -> [Output] {
    try await withThrowingTaskGroup(of: (Int, Output).self) { group in
        var results = [Output?](repeating: nil, count: items.count)
        var next = 0
        func start() {
            guard next < items.count else { return }
            let index = next
            let item = items[index]
            next += 1
            group.addTask { (index, try await work(item)) }
        }
        for _ in 0..<min(limit, items.count) { start() }
        while let (index, output) = try await group.next() {
            results[index] = output
            start()
        }
        return results.map { $0! }
    }
}

/// `concurrently`, handing each item's output to `handle` as it comes (in the order they finish), on the
/// caller's actor: what's done is used while the rest are under way.
func concurrently<Item: Sendable, Output: Sendable>(
    _ items: [Item], limit: Int, isolation: isolated (any Actor)? = #isolation,
    _ work: @escaping @Sendable (Item) async throws -> Output, each handle: (Item, Output) async throws -> Void
) async throws {
    try await withThrowingTaskGroup(of: (Item, Output).self) { group in
        var next = 0
        func start() {
            guard next < items.count else { return }
            let item = items[next]
            next += 1
            group.addTask { (item, try await work(item)) }
        }
        for _ in 0..<min(limit, items.count) { start() }
        while let (item, output) = try await group.next() {
            try await handle(item, output)
            start()
        }
    }
}

extension Array {
    func chunked(_ size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}
