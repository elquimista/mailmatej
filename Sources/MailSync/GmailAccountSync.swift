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
        self.client = GmailClient(tokens: tokens, session: urlSession)
        self.store = store
    }

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
        result.mailboxes = try await syncLabels()
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
        var incoming: [IncomingMessage] = []
        var copies: [(id: String, data: Data, mime: MIMEPart)] = []
        for message in messages {
            guard let data = message.raw.flatMap(Data.init(base64URL:)) else { continue }
            let mime = MIMEPart.parse(data)
            guard let stored = Self.incoming(message, raw: mime, mailboxLabels: mailboxLabels, archiveLabel: archiveLabel) else { continue }
            incoming.append(stored)
            copies.append((message.id, data, mime))
        }
        try store.upsertMessages(accountId: account.id, incoming)
        let ids = try store.messageIDsByRemoteID(accountId: account.id, remoteIds: copies.map(\.id))
        for copy in copies {
            guard let id = ids[copy.id] else { continue }
            try store.blobs.write(copy.data, accountId: account.id, blobId: copy.id)  // a Gmail message's blob id is its id
            let (body, parts) = BodyStructure.render(copy.mime, blobId: copy.id)
            try store.saveBody(messageId: id, body, parts: parts)
        }
        try store.setDownloadState(1, messageIds: Array(ids.values))
        return incoming.count
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
    /// and parts taken from it. Gmail's quota allows about 100 a minute per account (see `GmailClient`).
    public func downloadNextBatch(limit: Int = 50) async throws -> JMAPAccountSync.DownloadBatchResult {
        let pending = try store.pendingDownloads(accountId: account.id, limit: limit)
        guard !pending.isEmpty else { return .init(processed: 0, failed: 0) }
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
        return .init(processed: pending.count, failed: failed.count)
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
