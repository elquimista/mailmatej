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
    /// The labels as last stored, so a check that finds them unchanged writes nothing.
    private var storedLabels: [String]?

    public init(account: AccountRecord, tokens: GoogleTokenSource, store: MailStore, urlSession: URLSession = .shared) {
        self.account = account
        self.tokens = tokens
        self.client = GmailClient(tokens: tokens, session: urlSession)
        self.store = store
    }

    private let tokens: GoogleTokenSource
    /// The IMAP connections downloads use while they run, and where each message is in them.
    private var imapPool: [GmailIMAP] = []
    /// How many IMAP connections fetch at once: one alone is held to about 1 MB/s, and Gmail allows
    /// 15 an account (other apps' included).
    static let imapConnections = 4
    private var imapIndex: [String: (folder: String, uid: UInt32)]?
    /// IMAP failed (turned off for the account, say): downloads use the API until the next sync.
    private var imapUnavailable = false
    /// When the addresses it sends as were last asked for (see `syncIdentities`).
    private var lastIdentitySync: Date?
    /// Drafts' own ids (Gmail deletes a draft by it), by their messages' ids.
    private var draftIds: [String: String] = [:]

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
    /// `progress` hears how many message headers a full sync has downloaded, and of how many.
    @discardableResult
    public func sync(progress: @escaping @Sendable (_ downloaded: Int, _ total: Int) async -> Void = { _, _ in }) async throws
        -> JMAPAccountSync.Result
    {
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
                try await syncHistory(since: since, into: &result)
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
        return result
    }

    private func syncLabels() async throws -> Int {
        let labels = try await client.labels()
        let counts = try store.mailboxCounts(accountId: account.id)
        let user = labels.filter { $0.type == "user" }
        archiveLabel = user.first { $0.name.caseInsensitiveCompare(Self.archiveLabelName) == .orderedSame }?.id
        labelNames = Dictionary(user.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
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
            try store.recountMailboxes(accountId: account.id)
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
                    try store.upsertMessages(accountId: account.id, incoming)
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
                    try self.store.recountMailboxes(accountId: self.account.id)
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

    /// All Mail, Spam and Trash indexed: each message's folder, UID, Gmail id and size (also kept for
    /// the downloads).
    private func index(_ imap: GmailIMAP) async throws -> (GmailIMAP.Folders, [(folder: String, uid: UInt32, id: String, size: Int)]) {
        let folders = try await imap.folders()
        guard let all = folders.all else { throw GmailIMAP.IMAPError.malformed("no All Mail") }
        var entries: [(folder: String, uid: UInt32, id: String, size: Int)] = []
        for folder in [all, folders.spam, folders.trash].compactMap({ $0 }) {
            try await imap.examine(folder)
            entries += try await imap.index().map { (folder, $0.uid, $0.gmailId, $0.size) }
        }
        imapIndex = Dictionary(entries.map { ($0.id, ($0.folder, $0.uid)) }, uniquingKeysWith: { a, _ in a })
        return (folders, entries)
    }

    /// An IMAP message as the API would give it: its labels by the API's ids (IMAP names the system
    /// ones "\\Inbox" and so on, and the user's by name), Spam and Trash by its folder, Unread and
    /// Starred by its flags.
    private func gmailMessage(_ message: GmailIMAP.Message, folder: String, folders: GmailIMAP.Folders) -> GmailClient.Message {
        let byName = Dictionary(labelNames.map { ($0.value.lowercased(), $0.key) }, uniquingKeysWith: { a, _ in a })
        var labels = Set(message.labels.compactMap { label -> String? in
            switch label.lowercased() {
            case "\\inbox": "INBOX"
            case "\\sent": "SENT"
            case "\\draft": "DRAFT"
            case "\\starred": "STARRED"
            case "\\important": "IMPORTANT"
            case "\\spam": "SPAM"
            case "\\trash": "TRASH"
            default: byName[label.lowercased()]
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
    /// removed. New ones are what rules run on.
    private func syncHistory(since: String, into result: inout JMAPAccountSync.Result) async throws {
        var token: String?
        var added: [String] = []
        var changed = Set<String>()
        var deleted = Set<String>()
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
                for change in (record.labelsAdded ?? []) + (record.labelsRemoved ?? []) where !deleted.contains(change.message.id) {
                    changed.insert(change.message.id)
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
            // New mail comes whole; for mail stored here (a label changed), its labels, with its headers
            // from the copy here, or else from Gmail (its body follows with the downloads).
            let changed = Array(changed)
            let new = changed.filter { !known.contains($0) }
            let (refreshed, gone) = try await refresh(changed.filter { known.contains($0) && store.blobs.contains(accountId: account.id, blobId: $0) })
            let headersOnly = changed.filter { known.contains($0) && !refreshed.contains($0) && !gone.contains($0) }
            let (metadata, missingMetadata) = try await fetch(headersOnly, format: .metadata)
            let messages = metadata.compactMap(incoming)
            try store.upsertMessages(accountId: account.id, messages)
            let (whole, missingWhole) = try await fetch(new, format: .raw)
            let stored = try storeWhole(whole)
            deleted.formUnion(gone + missingMetadata + missingWhole)
            result.updated += refreshed.count + messages.count + stored
            let arrived = Set(whole.map(\.id))
            result.arrived = added.filter { arrived.contains($0) && !known.contains($0) }
        }
        let gone = deleted.intersection(known)
        if !gone.isEmpty {
            try store.deleteMessages(accountId: account.id, remoteIds: Array(gone))
            result.destroyed += gone.count
        }
        if let latest, latest != since { try store.setSyncState(latest, accountId: account.id, type: Self.historyState) }
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
            let (body, parts) = BodyStructure.render(mime, blobId: original.id)
            var message = original
            if message.snippet == nil { message.snippet = Self.preview(body.text ?? "") }
            guard let stored = Self.incoming(message, raw: mime, mailboxLabels: mailboxLabels, archiveLabel: archiveLabel) else { continue }
            incoming.append(stored)
            copies.append((message.id, data, body, parts))
        }
        try store.upsertMessages(accountId: account.id, incoming)
        let ids = try store.messageIDsByRemoteID(accountId: account.id, remoteIds: copies.map(\.id))
        for copy in copies {
            guard let id = ids[copy.id] else { continue }
            try store.blobs.write(copy.data, accountId: account.id, blobId: copy.id)  // a Gmail message's blob id is its id
            try store.saveBody(messageId: id, copy.body, parts: copy.parts)
        }
        try store.setDownloadState(1, messageIds: Array(ids.values))
        return incoming.count
    }

    /// A list's preview line from a message's text, as Gmail's snippet is: its start, on one line.
    static func preview(_ text: String) -> String {
        String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(200))
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
        try store.upsertMessages(accountId: account.id, incoming)
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
                onChange()  // catch up on what happened while not watching
                #if DEBUG
                    let logs = ProcessInfo.processInfo.environment["MMJ_DEBUG_GMAIL"] != nil
                    let signal: @Sendable () -> Void = {
                        if logs { NSLog("MMJ gmail idle: change announced") }
                        onChange()
                    }
                #else
                    let signal = onChange
                #endif
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
    /// `keywords/$seen` and `$flagged` are the Unread and Starred labels; a message's new set of
    /// mailboxes (`mailboxIds`) adds their labels and takes off the other mailboxes' (moving, as into a
    /// folder: Sent and Drafts stay); `mailboxIds/<id>` adds or takes off one. Archive is MailMate's
    /// "[Gmail]/Archive" label, made the first time it's needed.
    public func update(remoteIds: [String], patch: [String: JSONValue]) async throws {
        guard !remoteIds.isEmpty else { return }
        var add = Set<String>(), remove = Set<String>()
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
            default:
                break  // other keywords (tags, $junk) have no Gmail equivalent
            }
        }
        guard !add.isEmpty || !remove.isEmpty else { return }
        do {
            try await client.modify(remoteIds, add: Array(add), remove: Array(remove))
        } catch let error as GmailClient.APIError where error.status == 400 || error.status == 404 {
            try? await restore(remoteIds: remoteIds)  // back to Gmail's state
            throw JMAPAccountSync.ChangeRefused(count: remoteIds.count, deleting: false, reason: error.message)
        }
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
        try store.upsertMessages(accountId: account.id, found.compactMap(incoming))
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
            message, headers: raw.headers, hasAttachment: BodyStructure.hasAttachment(raw), mailboxLabels: mailboxLabels,
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

    /// Downloads messages over IMAP (the connection stays open while downloads go on): finds each in the
    /// index, fetches them whole by folder in batches, and stores their copies, bodies and parts.
    /// Returns those downloaded (the others aren't in the index: new since, or gone).
    private func imapDownload(_ pending: [MailStore.PendingDownload]) async throws -> [Int64] {
        let pool = try await openIMAP()
        let imap = pool[0]
        if imapIndex == nil { _ = try await index(imap) }
        var located: [String: [(item: MailStore.PendingDownload, uid: UInt32)]] = [:]
        func locate() {
            located = [:]
            for item in pending {
                if let place = imapIndex?[item.remoteId] { located[place.folder, default: []].append((item, place.uid)) }
            }
        }
        locate()
        if located.isEmpty {  // all newer than the index: index again, once
            _ = try await index(imap)
            locate()
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
        let (body, parts) = BodyStructure.render(raw, blobId: remoteId)
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

    /// The body to show and search, and the parts to keep (as JMAP's: embedded media from the HTML body
    /// and every attachment, named or not), their blob ids "<message blob id>.<part id>".
    static func render(raw: Data, blobId: String) -> (MessageBody, [MessagePart]) { render(MIMEPart.parse(raw), blobId: blobId) }

    /// Whether a message has attachments: parts other than pictures its HTML shows.
    static func hasAttachment(_ root: MIMEPart) -> Bool {
        BodyStructure(root).attachments.contains { $0.cid == nil || $0.disposition == "attachment" }
    }

    static func render(_ root: MIMEPart, blobId: String) -> (MessageBody, [MessagePart]) {
        let structure = BodyStructure(root)
        let text = structure.textBody.filter { $0.type.hasPrefix("text/") }.map { leaf in
            leaf.type == "text/html" ? JMAPAccountSync.plainText(fromHTML: leaf.text) : leaf.text
        }.joined(separator: "\n\n")
        var html: String?
        if structure.htmlBody.contains(where: { $0.type == "text/html" }) {
            html = structure.htmlBody.filter { $0.type.hasPrefix("text/") }.map { leaf in
                leaf.type == "text/html" ? leaf.text : "<pre style=\"white-space: pre-wrap\">" + JMAPAccountSync.escapeHTML(leaf.text) + "</pre>"
            }.joined()
        }
        var seen = Set<String>()
        let embedded = structure.htmlBody.filter { $0.cid != nil && !$0.type.hasPrefix("text/") }
        let parts = (embedded + structure.attachments).compactMap { leaf -> MessagePart? in
            guard seen.insert(leaf.part.partId).inserted else { return nil }
            return MessagePart(
                blobId: "\(blobId).\(leaf.part.partId)", cid: leaf.cid, type: leaf.type, name: leaf.name, size: leaf.part.content.count)
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

extension Array {
    func chunked(_ size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}
