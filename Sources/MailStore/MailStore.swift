import Foundation
import GRDB

/// The local source of truth. Sync engines write here; the UI only reads from here.
public final class MailStore: Sendable {
    public let dbPool: DatabasePool
    public let blobs: BlobStore

    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("MailMateJ", isDirectory: true)
    }

    let smartCatalog = SmartCatalog()

    public init(directory: URL = MailStore.defaultDirectory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = Configuration()
        config.label = "MailStore"
        config.prepareDatabase { db in
            // The last `n` labels of an address's domain ("x@a.b.example.co.uk", 2 → "co.uk"), for smart
            // mailboxes' Top-, Second- and Third-Level.
            db.add(function: DatabaseFunction("mmj_domain_level", argumentCount: 2, pure: true) { values in
                guard let email = String.fromDatabaseValue(values[0]), let n = Int.fromDatabaseValue(values[1]),
                    let at = email.lastIndex(of: "@")
                else { return nil }
                let labels = email[email.index(after: at)...].split(separator: ".")
                return labels.suffix(n).joined(separator: ".")
            })
            // A name's first (0) or last (1) word, for Name ▸ First and Last.
            db.add(function: DatabaseFunction("mmj_name_word", argumentCount: 2, pure: true) { values in
                guard let name = String.fromDatabaseValue(values[0]), let which = Int.fromDatabaseValue(values[1]) else { return nil }
                let words = name.split(whereSeparator: \.isWhitespace)
                return String((which == 0 ? words.first : words.last) ?? "")
            })
        }
        dbPool = try DatabasePool(path: directory.appendingPathComponent("mail.sqlite").path, configuration: config)
        try Schema.migrator.migrate(dbPool)
        blobs = BlobStore(root: directory.appendingPathComponent("Messages", isDirectory: true))
        try refreshSmartCatalog()
    }

    // MARK: Accounts

    public func accounts() throws -> [AccountRecord] {
        try dbPool.read { db in try AccountRecord.order(Column("sortOrder"), Column("name")).fetchAll(db) }
    }

    /// The accounts' order in the sidebar (dragged there), first to last.
    public func setAccountOrder(_ ids: [String]) throws {
        try dbPool.write { db in
            for (index, id) in ids.enumerated() {
                try db.execute(sql: "UPDATE account SET sortOrder = ? WHERE id = ?", arguments: [index, id])
            }
        }
    }

    public func account(id: String) throws -> AccountRecord? {
        try dbPool.read { db in try AccountRecord.fetchOne(db, key: id) }
    }

    public func save(_ account: AccountRecord) throws {
        try dbPool.write { db in try account.save(db) }
    }

    /// Removes an account and, through cascades, all of its local data.
    public func deleteAccount(id: String) throws {
        try dbPool.write { db in _ = try AccountRecord.deleteOne(db, key: id) }
        blobs.removeAll(accountId: id)
    }

    // MARK: Sync state

    public func syncState(accountId: String, type: String) throws -> String? {
        try dbPool.read { db in
            try String.fetchOne(
                db, sql: "SELECT state FROM syncState WHERE accountId = ? AND objectType = ?",
                arguments: [accountId, type])
        }
    }

    public func setSyncState(_ state: String?, accountId: String, type: String) throws {
        try dbPool.write { db in
            if let state {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO syncState (accountId, objectType, state) VALUES (?, ?, ?)",
                    arguments: [accountId, type, state])
            } else {
                try db.execute(
                    sql: "DELETE FROM syncState WHERE accountId = ? AND objectType = ?", arguments: [accountId, type])
            }
        }
    }

    // MARK: Identities

    public func replaceIdentities(accountId: String, _ identities: [(remoteId: String, name: String, email: String)])
        throws
    {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM identity WHERE accountId = ?", arguments: [accountId])
            for i in identities {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO identity (accountId, remoteId, name, email) VALUES (?, ?, ?, ?)",
                    arguments: [accountId, i.remoteId, i.name, i.email.lowercased()])
            }
        }
    }

    /// The sending identities of every account, in account order.
    /// The From choices, per account in account order. Where an account lists its addresses (Email
    /// Address(es)), those, in that order, as MailMate shows them: with the server's identity for the
    /// address if it has one, else sent through the account's own identity (the server checks only the
    /// envelope sender, as an SMTP server would). Otherwise the server's identities.
    public func identities() throws -> [IdentityRecord] {
        let accounts = try accounts()
        let byAccount = Dictionary(grouping: try allIdentities(), by: \.accountId)
        var result: [IdentityRecord] = []
        for account in accounts where account.isEnabled {
            let server = byAccount[account.id] ?? []
            let listed = AccountRecord.namedAddresses(in: account.emailAddresses)
            guard !listed.isEmpty, let main = server.first(where: { $0.email == account.username.lowercased() }) ?? server.first
            else {
                result += server
                continue
            }
            for (name, email) in listed {
                if var identity = server.first(where: { $0.email == email }) {
                    if let name { identity.name = name }
                    result.append(identity)
                } else {
                    result.append(IdentityRecord(
                        accountId: account.id, remoteId: main.remoteId,
                        name: name ?? (account.fullName.isEmpty ? main.name : account.fullName), email: email,
                        envelopeEmail: main.email))
                }
            }
        }
        return result
    }

    private func allIdentities() throws -> [IdentityRecord] {
        try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT i.accountId, i.remoteId, CASE WHEN i.name = '' THEN a.fullName ELSE i.name END AS name, i.email
                    FROM identity i JOIN account a ON a.id = i.accountId
                    WHERE a.isEnabled ORDER BY a.sortOrder, a.name, i.email
                    """
            ).map { IdentityRecord(accountId: $0["accountId"], remoteId: $0["remoteId"], name: $0["name"], email: $0["email"]) }
        }
    }

    /// An address the user has mail with, for completing addresses while composing.
    public struct KnownAddress: Sendable, Equatable {
        public var email: String
        /// Its most common display name, if any.
        public var name: String?
        /// How often it appears in mail, and how often the user sent to it.
        public var seen: Int
        public var sentTo: Int

        public init(email: String, name: String?, seen: Int, sentTo: Int) {
            self.email = email
            self.name = name
            self.seen = seen
            self.sentTo = sentTo
        }
    }

    /// Every address in stored mail, with its most common name and counts (see `KnownAddress`).
    public func knownAddresses() throws -> [KnownAddress] {
        try dbPool.read { db in
            let sentIDs = "SELECT mm.messageId FROM message_mailbox mm JOIN mailbox b ON b.id = mm.mailboxId WHERE b.role = 'sent'"
            let rows = try Row.fetchAll(db, sql: """
                SELECT a.email AS email, COUNT(*) AS seen,
                       SUM(a.role IN (\(AddressRole.to.rawValue), \(AddressRole.cc.rawValue), \(AddressRole.bcc.rawValue))
                           AND a.messageId IN (\(sentIDs))) AS sentTo
                FROM address a WHERE a.email LIKE '%_@_%' GROUP BY a.email
                """)
            let names = try Row.fetchAll(db, sql: """
                SELECT email, name, COUNT(*) AS uses FROM address
                WHERE name IS NOT NULL AND name <> '' AND email LIKE '%_@_%' GROUP BY email, name
                """)
            var bestName: [String: (name: String, uses: Int)] = [:]
            for row in names {
                let email: String = row["email"], name: String = row["name"], uses: Int = row["uses"]
                if uses > bestName[email]?.uses ?? 0 { bestName[email] = (name, uses) }
            }
            return rows.map { row in
                let email: String = row["email"]
                return KnownAddress(email: email, name: bestName[email]?.name, seen: row["seen"], sentTo: row["sentTo"] ?? 0)
            }
        }
    }

    /// All of the user's own addresses, across accounts.
    public func myAddresses() throws -> Set<String> {
        try dbPool.read { db in
            var set = Set(try String.fetchAll(db, sql: "SELECT email FROM identity"))
            for name in try String.fetchAll(db, sql: "SELECT username FROM account") where name.contains("@") {
                set.insert(name.lowercased())
            }
            for list in try String.fetchAll(db, sql: "SELECT emailAddresses FROM account") {
                set.formUnion(AccountRecord.addresses(in: list))
            }
            return set
        }
    }

    // MARK: Mailboxes

    public func mailboxes() throws -> [MailboxRecord] {
        try dbPool.read { db in
            try MailboxRecord.fetchAll(db, sql: "SELECT * FROM mailbox ORDER BY accountId, sortOrder, name")
        }
    }

    /// Upserts and deletes mailboxes. With `replaceAll`, mailboxes not in `upserts` are removed.
    public func applyMailboxes(accountId: String, upserts: [IncomingMailbox], destroyed: [String], replaceAll: Bool)
        throws
    {
        try dbPool.write { db in
            let stmt = try db.cachedStatement(sql: """
                INSERT INTO mailbox (accountId, remoteId, parentRemoteId, name, role, sortOrder, totalEmails, unreadEmails)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (accountId, remoteId) DO UPDATE SET
                    parentRemoteId = excluded.parentRemoteId, name = excluded.name, role = excluded.role,
                    sortOrder = excluded.sortOrder, totalEmails = excluded.totalEmails,
                    unreadEmails = excluded.unreadEmails
                """)
            for m in upserts {
                try stmt.execute(arguments: [
                    accountId, m.remoteId, m.parentRemoteId, m.name, m.role, m.sortOrder, m.totalEmails,
                    m.unreadEmails,
                ])
            }
            if replaceAll {
                let keep = Set(upserts.map(\.remoteId))
                let existing = try String.fetchAll(
                    db, sql: "SELECT remoteId FROM mailbox WHERE accountId = ?", arguments: [accountId])
                for remoteId in existing where !keep.contains(remoteId) {
                    try db.execute(
                        sql: "DELETE FROM mailbox WHERE accountId = ? AND remoteId = ?", arguments: [accountId, remoteId])
                }
            }
            for remoteId in destroyed {
                try db.execute(
                    sql: "DELETE FROM mailbox WHERE accountId = ? AND remoteId = ?", arguments: [accountId, remoteId])
            }
            try Self.inferArchive(db, accountId: accountId, serverArchive: upserts.first { $0.role == "archive" }?.remoteId)
        }
    }

    /// Many servers don't give the Archive folder JMAP's archive role. Where an account has no mailbox
    /// with it, a top-level mailbox named "Archive" stands in (locally), so Archive and the unified Archive
    /// mailbox use it. A mailbox the server does mark as Archive takes over from it.
    static func inferArchive(_ db: Database, accountId: String, serverArchive: String?) throws {
        if let serverArchive {
            try db.execute(
                sql: "UPDATE mailbox SET role = NULL WHERE accountId = ? AND role = 'archive' AND remoteId != ?",
                arguments: [accountId, serverArchive])
            return
        }
        try db.execute(
            sql: """
                UPDATE mailbox SET role = 'archive'
                WHERE id = (SELECT id FROM mailbox WHERE accountId = ? AND role IS NULL AND parentRemoteId IS NULL
                            AND name = 'Archive' COLLATE NOCASE ORDER BY sortOrder LIMIT 1)
                  AND NOT EXISTS (SELECT 1 FROM mailbox WHERE accountId = ? AND role = 'archive')
                """,
            arguments: [accountId, accountId])
    }

    // MARK: Messages (writes)

    /// Inserts or updates messages in a single transaction.
    public func upsertMessages(accountId: String, _ messages: [IncomingMessage]) throws {
        guard !messages.isEmpty else { return }
        try dbPool.write { db in
            var mailboxIds: [String: Int64] = [:]
            for row in try Row.fetchAll(
                db, sql: "SELECT remoteId, id FROM mailbox WHERE accountId = ?", arguments: [accountId])
            {
                mailboxIds[row["remoteId"]] = row["id"]
            }

            let upsert = try db.cachedStatement(sql: """
                INSERT INTO message (accountId, remoteId, threadId, blobId, messageIdHeader, inReplyTo, subject,
                    sortSubject, fromDisplay, fromEmail, preview, size, receivedAt, sentAt, hasAttachment,
                    isSeen, isFlagged, isAnswered, isDraft, referencesHeader)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (accountId, remoteId) DO UPDATE SET
                    threadId = excluded.threadId, blobId = excluded.blobId,
                    messageIdHeader = excluded.messageIdHeader, inReplyTo = excluded.inReplyTo,
                    referencesHeader = excluded.referencesHeader,
                    subject = excluded.subject, sortSubject = excluded.sortSubject,
                    fromDisplay = excluded.fromDisplay, fromEmail = excluded.fromEmail, preview = excluded.preview,
                    size = excluded.size, receivedAt = excluded.receivedAt, sentAt = excluded.sentAt,
                    hasAttachment = excluded.hasAttachment, isSeen = excluded.isSeen,
                    isFlagged = excluded.isFlagged, isAnswered = excluded.isAnswered, isDraft = excluded.isDraft,
                    downloadState = CASE WHEN blobId = excluded.blobId THEN downloadState ELSE 0 END
                RETURNING id
                """)
            let clearMailboxes = try db.cachedStatement(sql: "DELETE FROM message_mailbox WHERE messageId = ?")
            let clearKeywords = try db.cachedStatement(sql: "DELETE FROM message_keyword WHERE messageId = ?")
            let clearAddresses = try db.cachedStatement(sql: "DELETE FROM address WHERE messageId = ?")
            let clearFTS = try db.cachedStatement(sql: "DELETE FROM message_fts WHERE rowid = ?")
            let addMailbox = try db.cachedStatement(
                sql: "INSERT OR IGNORE INTO message_mailbox (messageId, mailboxId) VALUES (?, ?)")
            let addKeyword = try db.cachedStatement(
                sql: "INSERT OR IGNORE INTO message_keyword (messageId, keyword) VALUES (?, ?)")
            let addAddress = try db.cachedStatement(
                sql: "INSERT OR REPLACE INTO address (messageId, role, position, name, email) VALUES (?, ?, ?, ?, ?)")
            let addFTS = try db.cachedStatement(
                sql: "INSERT INTO message_fts (rowid, subject, addresses, body) VALUES (?, ?, ?, ?)")

            for m in messages {
                let keywords = Set(m.keywords.map { $0.lowercased() })
                let from = m.addresses.first { $0.role == .from }
                let fromDisplay = from.map { ($0.name?.isEmpty == false ? $0.name! : $0.email) } ?? ""
                let args: [(any DatabaseValueConvertible)?] = [
                    accountId, m.remoteId, m.threadId, m.blobId, m.messageIdHeader, m.inReplyTo, m.subject,
                    Self.sortSubject(m.subject), fromDisplay, from?.email.lowercased() ?? "", m.preview, m.size,
                    m.receivedAt.timeIntervalSince1970, m.sentAt?.timeIntervalSince1970, m.hasAttachment,
                    keywords.contains("$seen"), keywords.contains("$flagged"), keywords.contains("$answered"),
                    keywords.contains("$draft"), m.references.joined(separator: " "),
                ]
                guard let id = try Int64.fetchOne(upsert, arguments: StatementArguments(args)) else { continue }

                try clearMailboxes.execute(arguments: [id])
                try clearKeywords.execute(arguments: [id])
                try clearAddresses.execute(arguments: [id])
                try clearFTS.execute(arguments: [id])

                for remote in m.mailboxRemoteIds {
                    if let mailboxId = mailboxIds[remote] { try addMailbox.execute(arguments: [id, mailboxId]) }
                }
                for k in keywords { try addKeyword.execute(arguments: [id, k]) }
                var positions: [AddressRole: Int] = [:]
                for a in m.addresses {
                    let pos = positions[a.role, default: 0]
                    positions[a.role] = pos + 1
                    try addAddress.execute(arguments: [id, a.role.rawValue, pos, a.name, a.email.lowercased()])
                }
                let addressText = m.addresses.map { [$0.name, $0.email].compactMap { $0 }.joined(separator: " ") }
                    .joined(separator: " ")
                try addFTS.execute(arguments: [id, m.subject, addressText, m.preview])
            }
        }
    }

    public func deleteMessages(accountId: String, remoteIds: [String]) throws {
        guard !remoteIds.isEmpty else { return }
        try dbPool.write { db in
            for chunk in remoteIds.chunked(500) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                try db.execute(
                    sql: "DELETE FROM message WHERE accountId = ? AND remoteId IN (\(marks))",
                    arguments: StatementArguments([accountId] + chunk))
            }
        }
    }

    // MARK: Full download

    public struct PendingDownload: Sendable {
        public var id: Int64
        public var remoteId: String
        public var blobId: String
        public var size: Int
        public var hasBody: Bool

        public init(id: Int64, remoteId: String, blobId: String, size: Int, hasBody: Bool) {
            self.id = id
            self.remoteId = remoteId
            self.blobId = blobId
            self.size = size
            self.hasBody = hasBody
        }
    }

    /// Messages of an account not yet fully downloaded, newest first (so new mail goes first).
    public func pendingDownloads(accountId: String, limit: Int) throws -> [PendingDownload] {
        try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT m.id, m.remoteId, m.blobId, m.size,
                           EXISTS (SELECT 1 FROM message_body b WHERE b.messageId = m.id) AS hasBody
                    FROM message m
                    WHERE m.accountId = ? AND m.downloadState = 0
                    ORDER BY m.receivedAt DESC LIMIT ?
                    """,
                arguments: [accountId, limit]
            ).map { PendingDownload(id: $0["id"], remoteId: $0["remoteId"], blobId: $0["blobId"], size: $0["size"], hasBody: $0["hasBody"]) }
        }
    }

    /// Mailboxes holding the next `limit` messages to download: the ones the download is working on.
    public func mailboxIdsOfPendingDownloads(accountId: String, limit: Int) throws -> Set<Int64> {
        try dbPool.read { db in
            Set(try Int64.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT mm.mailboxId FROM (
                        SELECT id FROM message WHERE accountId = ? AND downloadState = 0
                        ORDER BY receivedAt DESC LIMIT ?
                    ) p JOIN message_mailbox mm ON mm.messageId = p.id
                    """,
                arguments: [accountId, limit]))
        }
    }

    public func setDownloadState(_ state: Int, messageIds: [Int64]) throws {
        guard !messageIds.isEmpty else { return }
        try dbPool.write { db in
            for chunk in messageIds.chunked(500) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                try db.execute(
                    sql: "UPDATE message SET downloadState = ? WHERE id IN (\(marks))",
                    arguments: StatementArguments([state] + chunk.map { $0 as Int64 }))
            }
        }
    }

    /// Lets messages that failed to download in an earlier run be tried again.
    public func retryFailedDownloads() throws {
        try dbPool.write { db in try db.execute(sql: "UPDATE message SET downloadState = 0 WHERE downloadState = 2") }
    }

    /// (downloaded, total) messages for an account.
    public func downloadProgress(accountId: String) throws -> (downloaded: Int, total: Int) {
        try dbPool.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT SUM(downloadState = 1) AS done, COUNT(*) AS total FROM message WHERE accountId = ?",
                arguments: [accountId])
            return ((row?["done"] as Int?) ?? 0, (row?["total"] as Int?) ?? 0)
        }
    }

    public func saveBody(messageId: Int64, _ body: MessageBody, parts: [MessagePart] = []) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO message_body (messageId, html, text, fetchedAt) VALUES (?, ?, ?, ?)",
                arguments: [messageId, body.html, body.text, Date().timeIntervalSince1970])
            try db.execute(sql: "DELETE FROM message_part WHERE messageId = ?", arguments: [messageId])
            for (position, p) in parts.enumerated() {
                try db.execute(
                    sql: """
                        INSERT OR REPLACE INTO message_part (messageId, blobId, cid, type, name, size, position)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [messageId, p.blobId, p.cid.map(MessagePart.normalizeCID), p.type, p.name, p.size, position])
            }
            if let text = body.text {
                try db.execute(
                    sql: "UPDATE message_fts SET body = ? WHERE rowid = ?", arguments: [String(text.prefix(100_000)), messageId])
            }
        }
    }

    // MARK: Local edits (applied right away; the server copy follows)

    /// What the server needs to change a message: its account and remote id.
    public struct MessageRef: Sendable, Hashable {
        public var id: Int64
        public var accountId: String
        public var remoteId: String
    }

    public func refs(ids: [Int64]) throws -> [MessageRef] {
        guard !ids.isEmpty else { return [] }
        return try dbPool.read { db in
            try Row.fetchAll(
                db, sql: "SELECT id, accountId, remoteId FROM message WHERE id IN (\(Self.placeholders(ids.count)))",
                arguments: StatementArguments(ids)
            ).map { MessageRef(id: $0["id"], accountId: $0["accountId"], remoteId: $0["remoteId"]) }
        }
    }

    /// An account's mailbox with a JMAP role ("archive", "junk", "trash", ...).
    public func mailbox(accountId: String, role: String) throws -> MailboxRecord? {
        try mailboxes().first { $0.accountId == accountId && $0.role == role }
    }

    /// Which of these messages are in a mailbox with this role.
    public func messageIDs(_ ids: [Int64], inRole role: String) throws -> Set<Int64> {
        guard !ids.isEmpty else { return [] }
        return try dbPool.read { db in
            Set(try Int64.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT mm.messageId FROM message_mailbox mm JOIN mailbox b ON b.id = mm.mailboxId
                    WHERE b.role = ? AND mm.messageId IN (\(Self.placeholders(ids.count)))
                    """,
                arguments: StatementArguments([role] as [any DatabaseValueConvertible] + ids)))
        }
    }

    /// Sets or clears a keyword ("$seen", "$flagged", ...) and its column.
    public func setKeyword(_ keyword: String, _ on: Bool, messageIds: [Int64]) throws {
        guard !messageIds.isEmpty else { return }
        let column = ["$seen": "isSeen", "$flagged": "isFlagged", "$answered": "isAnswered", "$draft": "isDraft"][keyword]
        try dbPool.write { db in
            let list = Self.placeholders(messageIds.count)
            if let column {
                try db.execute(
                    sql: "UPDATE message SET \(column) = ? WHERE id IN (\(list))",
                    arguments: StatementArguments([on] as [any DatabaseValueConvertible] + messageIds))
            }
            for id in messageIds {
                try db.execute(
                    sql: on ? "INSERT OR IGNORE INTO message_keyword (messageId, keyword) VALUES (?, ?)"
                        : "DELETE FROM message_keyword WHERE messageId = ? AND keyword = ?",
                    arguments: [id, keyword])
            }
        }
    }

    /// Puts the messages in exactly one mailbox, as a move does.
    public func moveMessages(_ messageIds: [Int64], toMailboxId mailboxId: Int64) throws {
        guard !messageIds.isEmpty else { return }
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM message_mailbox WHERE messageId IN (\(Self.placeholders(messageIds.count)))",
                arguments: StatementArguments(messageIds))
            for id in messageIds {
                try db.execute(
                    sql: "INSERT INTO message_mailbox (messageId, mailboxId) VALUES (?, ?)", arguments: [id, mailboxId])
            }
        }
    }

    /// Each message's mailboxes (local ids), e.g. to put messages back where they were.
    public func mailboxIDs(messageIds: [Int64]) throws -> [Int64: [Int64]] {
        guard !messageIds.isEmpty else { return [:] }
        return try dbPool.read { db in
            var result: [Int64: [Int64]] = [:]
            for row in try Row.fetchAll(
                db,
                sql: "SELECT messageId, mailboxId FROM message_mailbox WHERE messageId IN (\(Self.placeholders(messageIds.count)))",
                arguments: StatementArguments(messageIds))
            {
                result[row["messageId"], default: []].append(row["mailboxId"])
            }
            return result
        }
    }

    /// Puts a message in exactly these mailboxes.
    /// Renames a mailbox here (its server follows; see `AppModel.renameMailbox`).
    public func renameMailbox(id: Int64, to name: String) throws {
        try dbPool.write { db in try db.execute(sql: "UPDATE mailbox SET name = ? WHERE id = ?", arguments: [name, id]) }
    }

    public func setMailboxes(_ mailboxIds: [Int64], messageId: Int64) throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM message_mailbox WHERE messageId = ?", arguments: [messageId])
            for box in mailboxIds {
                try db.execute(sql: "INSERT INTO message_mailbox (messageId, mailboxId) VALUES (?, ?)", arguments: [messageId, box])
            }
        }
    }

    /// Messages stored before References were (remote ids), for the sync to fill in.
    public func remoteIDsMissingReferences(accountId: String, limit: Int) throws -> [String] {
        try dbPool.read { db in
            try String.fetchAll(
                db, sql: "SELECT remoteId FROM message WHERE accountId = ? AND referencesHeader IS NULL LIMIT ?",
                arguments: [accountId, limit])
        }
    }

    // MARK: Change queue

    /// Keeps a change for the account's server, after any already queued.
    public func enqueueChange(accountId: String, _ change: Data) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "INSERT INTO change_queue (accountId, change, createdAt) VALUES (?, ?, ?)",
                arguments: [accountId, change, Date().timeIntervalSince1970])
        }
    }

    /// The account's queued changes, oldest first.
    public func queuedChanges(accountId: String) throws -> [(id: Int64, change: Data)] {
        try dbPool.read { db in
            try Row.fetchAll(
                db, sql: "SELECT id, change FROM change_queue WHERE accountId = ? ORDER BY id", arguments: [accountId]
            ).map { ($0["id"], $0["change"]) }
        }
    }

    public func queuedChangeCount(accountId: String) throws -> Int {
        try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM change_queue WHERE accountId = ?", arguments: [accountId]) ?? 0
        }
    }

    public func removeQueuedChange(id: Int64) throws {
        try dbPool.write { db in try db.execute(sql: "DELETE FROM change_queue WHERE id = ?", arguments: [id]) }
    }

    /// Replaces a queued change in place (what's left of it after part went through).
    public func replaceQueuedChange(id: Int64, with change: Data) throws {
        try dbPool.write { db in
            try db.execute(sql: "UPDATE change_queue SET change = ? WHERE id = ?", arguments: [change, id])
        }
    }

    /// Messages whose recipient groups haven't been fetched (see the v10 migration).
    public func remoteIDsMissingRecipientGroups(accountId: String, limit: Int) throws -> [String] {
        try dbPool.read { db in
            try String.fetchAll(
                db, sql: "SELECT remoteId FROM message WHERE accountId = ? AND recipientGroupsFetched = 0 LIMIT ?",
                arguments: [accountId, limit])
        }
    }

    /// Adds empty recipient groups' names to messages by remote id, and marks them fetched.
    public func addRecipientGroups(accountId: String, _ groups: [String: [IncomingMessage.Address]]) throws {
        guard !groups.isEmpty else { return }
        try dbPool.write { db in
            for (remoteId, names) in groups {
                guard let id = try Int64.fetchOne(
                    db, sql: "SELECT id FROM message WHERE accountId = ? AND remoteId = ?", arguments: [accountId, remoteId])
                else { continue }
                for (position, a) in names.enumerated() {
                    try db.execute(
                        sql: "INSERT OR REPLACE INTO address (messageId, role, position, name, email) VALUES (?, ?, ?, ?, '')",
                        arguments: [id, a.role.rawValue, position, a.name])
                }
                try db.execute(sql: "UPDATE message SET recipientGroupsFetched = 1 WHERE id = ?", arguments: [id])
            }
        }
    }

    /// Stores References for messages by remote id ([] for none, so they aren't asked for again).
    public func setReferences(accountId: String, _ references: [String: [String]]) throws {
        guard !references.isEmpty else { return }
        try dbPool.write { db in
            for (remoteId, ids) in references {
                try db.execute(
                    sql: "UPDATE message SET referencesHeader = ? WHERE accountId = ? AND remoteId = ?",
                    arguments: [ids.joined(separator: " "), accountId, remoteId])
            }
        }
    }

    /// A message's keywords ("$seen", "$flagged", ...).
    public func keywords(messageId: Int64) throws -> [String] {
        try dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT keyword FROM message_keyword WHERE messageId = ?", arguments: [messageId])
        }
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    /// A message's saved parts (embedded images and attachments), in the message's order.
    public func parts(messageId: Int64) throws -> [MessagePart] {
        try dbPool.read { db in
            try Row.fetchAll(
                db, sql: "SELECT blobId, cid, type, name, size FROM message_part WHERE messageId = ? ORDER BY position",
                arguments: [messageId]
            ).map { MessagePart(blobId: $0["blobId"], cid: $0["cid"], type: $0["type"], name: $0["name"], size: $0["size"]) }
        }
    }

    /// The part of a message with Content-ID `cid`, plus the message's account.
    public func part(messageId: Int64, cid: String) throws -> (accountId: String, part: MessagePart)? {
        try dbPool.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT m.accountId, p.blobId, p.cid, p.type, p.name, p.size
                    FROM message_part p JOIN message m ON m.id = p.messageId
                    WHERE p.messageId = ? AND p.cid = ?
                    """,
                arguments: [messageId, MessagePart.normalizeCID(cid)]
            ).map {
                ($0["accountId"], MessagePart(blobId: $0["blobId"], cid: $0["cid"], type: $0["type"], name: $0["name"], size: $0["size"]))
            }
        }
    }

    // MARK: Remote content allow-list

    /// Whether remote content from `email` loads automatically (allowed by address or by domain).
    public func isRemoteContentAllowed(email: String) throws -> Bool {
        let address = email.lowercased()
        let domain = address.split(separator: "@").last.map { "@" + $0 } ?? address
        return try dbPool.read { db in
            try Bool.fetchOne(
                db, sql: "SELECT EXISTS (SELECT 1 FROM remote_content_allow WHERE value IN (?, ?))",
                arguments: [address, domain]) ?? false
        }
    }

    /// The allow-list entries matching `email` (its address and/or its "@domain").
    public func remoteContentAllowEntries(email: String) throws -> [String] {
        let address = email.lowercased()
        let domain = address.split(separator: "@").last.map { "@" + $0 } ?? address
        return try dbPool.read { db in
            try String.fetchAll(
                db, sql: "SELECT value FROM remote_content_allow WHERE value IN (?, ?) ORDER BY value",
                arguments: [address, domain])
        }
    }

    /// Adds `"name@domain"` or `"@domain"` to the allow-list.
    public func allowRemoteContent(_ value: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO remote_content_allow (value, addedAt) VALUES (?, ?)",
                arguments: [value.lowercased(), Date().timeIntervalSince1970])
        }
    }

    public func disallowRemoteContent(_ value: String) throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM remote_content_allow WHERE value = ?", arguments: [value.lowercased()])
        }
    }

    // MARK: Messages (reads)

    /// Ordered IDs for a list. Cheap even for a million messages; rows are fetched separately.
    /// One row of a threaded list.
    public struct ThreadedRow: Sendable, Hashable {
        public var id: Int64
        /// Identifies the conversation in this list: the account and its first message (see `threadKeys`).
        public var thread: String
        /// 0 for a thread's first message, 1 for its replies.
        public var depth: Int
        /// How many messages the thread has in this list (on its first row; 1 elsewhere).
        public var size: Int
        /// Whether any message of the thread is unread (on its first row).
        public var anyUnread: Bool
        /// Whether replies hang under this message (it gets a chevron).
        public var hasReplies: Bool
        /// When the thread's newest message arrived (on its first row; the row's own date elsewhere): a
        /// closed thread shows this date, so a new reply doesn't look like old mail.
        public var newestAt: Double

        public init(
            id: Int64, thread: String, depth: Int, size: Int, anyUnread: Bool, hasReplies: Bool = false, newestAt: Double = 0
        ) {
            self.id = id
            self.thread = thread
            self.depth = depth
            self.size = size
            self.anyUnread = anyUnread
            self.hasReplies = hasReplies
            self.newestAt = newestAt
        }
    }

    /// What threading needs to know of a message.
    public struct ThreadInput: Sendable {
        public var id: Int64
        public var account: String
        public var at: Double
        public var seen: Bool
        /// Its Message-ID and the reply headers that place it in a conversation.
        public var messageId: String?
        public var inReplyTo: String?
        public var references: [String]

        public init(
            id: Int64, account: String = "", at: Double, seen: Bool, messageId: String? = nil, inReplyTo: String? = nil,
            references: [String] = []
        ) {
            self.id = id
            self.account = account
            self.at = at
            self.seen = seen
            self.messageId = messageId
            self.inReplyTo = inReplyTo
            self.references = references
        }

        init(_ row: Row) {
            let references: String? = row["referencesHeader"]
            self.init(
                id: row["id"], account: row["accountId"], at: row["receivedAt"], seen: row["isSeen"],
                messageId: row["messageIdHeader"], inReplyTo: row["inReplyTo"],
                references: references.map { $0.split(separator: " ").map(String.init) } ?? [])
        }
    }

    private static let threadColumns =
        "m.id, m.accountId, m.receivedAt, m.isSeen, m.messageIdHeader, m.inReplyTo, m.referencesHeader"

    /// A threaded list: its rows, and the thread of every message in it (those inside closed threads too).
    public struct ThreadedList: Sendable {
        public var rows: [ThreadedRow]
        public var threadOf: [Int64: String]
    }

    /// A list's messages grouped into conversations, as MailMate shows threads: each thread where its
    /// first message in `sort` order would be (by date: where its newest message is, so a new reply
    /// brings the thread to the new mail in either direction), as a reply tree (see `thread`). Threads start collapsed,
    /// as in MailMate, at every level: replies show only for threads in `expanded`, and replies to a
    /// reply only under messages in `opened`.
    public func threadedMessages(
        scope: MessageScope, sort: MessageSort = .newestFirst, search: String? = nil, expanded: Set<String> = [],
        opened: Set<Int64> = []
    ) throws -> ThreadedList {
        let (filter, args) = self.filter(scope: scope, search: search)
        let sql = "SELECT \(Self.threadColumns) FROM message m WHERE \(filter) ORDER BY \(Self.orderBy(sort))"
        let rows = try dbPool.read { db in try Row.fetchAll(db, sql: sql, arguments: args).map(ThreadInput.init) }
        return ThreadedList(
            rows: Self.thread(rows, expanded: expanded, opened: opened, placeAtNewest: sort.key == .receivedAt),
            threadOf: Self.threadKeys(rows))
    }

    /// What threading needs to know of these messages, in the given order (missing ones left out).
    public func threadInfo(ids: [Int64]) throws -> [ThreadInput] {
        guard !ids.isEmpty else { return [] }
        let found = try dbPool.read { db in
            try Row.fetchAll(
                db, sql: "SELECT \(Self.threadColumns) FROM message m WHERE m.id IN (\(Self.placeholders(ids.count)))",
                arguments: StatementArguments(ids)
            ).map(ThreadInput.init)
        }
        let byID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byID[$0] }
    }

    /// Each message's parent in this list, as MailMate links replies: the message it answers directly
    /// (its In-Reply-To, or without one the last of its References), when that message is in the list.
    /// Nothing further up the References counts, so where the message in between isn't listed (a reply
    /// of yours, in Sent, between two messages in the Inbox) the thread splits, as in MailMate.
    static func parents(_ rows: [ThreadInput]) -> [Int64: Int64] {
        var byMessageId: [String: Int64] = [:]
        for row in rows {
            if let mid = row.messageId, byMessageId[row.account + " " + mid] == nil { byMessageId[row.account + " " + mid] = row.id }
        }
        var parents: [Int64: Int64] = [:]
        for row in rows {
            guard let direct = row.inReplyTo ?? row.references.last,
                let parent = byMessageId[row.account + " " + direct], parent != row.id
            else { continue }
            parents[row.id] = parent
        }
        return parents
    }

    /// Each message's thread in this list: "<account>:<id of the thread's first message>". Messages caught
    /// in a loop of reply headers get the loop's lowest id as their first message.
    public static func threadKeys(_ rows: [ThreadInput]) -> [Int64: String] {
        let parents = parents(rows)
        let account = Dictionary(rows.map { ($0.id, $0.account) }, uniquingKeysWith: { a, _ in a })
        var root: [Int64: Int64] = [:]
        for row in rows where root[row.id] == nil {
            var path: [Int64] = [row.id]
            var seen: Set<Int64> = [row.id]
            var top = row.id
            while let parent = parents[top] {
                if let known = root[parent] { top = known; break }
                if !seen.insert(parent).inserted {
                    top = path[path.firstIndex(of: parent)!...].min()!  // A loop: its lowest id heads it.
                    break
                }
                path.append(parent)
                top = parent
            }
            for id in path { root[id] = top }
        }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.id, "\(account[$0.id] ?? ""):\(root[$0.id] ?? $0.id)") })
    }

    /// The messages above `id` in its thread, from the thread's first message down to its parent.
    public static func ancestors(of id: Int64, in rows: [ThreadInput]) -> [Int64] {
        let parents = parents(rows)
        var chain: [Int64] = []
        var seen: Set<Int64> = [id]
        var current = id
        while let parent = parents[current], seen.insert(parent).inserted {
            chain.append(parent)
            current = parent
        }
        return chain.reversed()
    }

    /// Groups rows (in list order) into threads (see `parents`). Each thread goes where its first row is
    /// (with `placeAtNewest`, where its newest message is), as a reply tree: every message under the one
    /// it answers, one level deeper, siblings oldest first.
    public static func thread(
        _ rows: [ThreadInput], expanded: Set<String>, opened: Set<Int64> = [], placeAtNewest: Bool = false
    ) -> [ThreadedRow] {
        let keys = threadKeys(rows)
        let parents = parents(rows)
        var order: [String] = []
        var members: [String: [ThreadInput]] = [:]
        for row in rows {
            let key = keys[row.id]!
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(row)
        }
        if placeAtNewest {
            var position: [Int64: Int] = [:]
            for (index, row) in rows.enumerated() { position[row.id] = index }
            func anchor(_ key: String) -> Int {
                position[members[key]!.max { ($0.at, $0.id) < ($1.at, $1.id) }!.id]!
            }
            let anchors = Dictionary(uniqueKeysWithValues: order.map { ($0, anchor($0)) })
            order.sort { anchors[$0]! < anchors[$1]! }
        }
        var result: [ThreadedRow] = []
        result.reserveCapacity(rows.count)
        for thread in order {
            let messages = members[thread]!.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
            let anyUnread = messages.contains { !$0.seen }
            let size = messages.count
            guard size > 1 else {
                result.append(ThreadedRow(
                    id: messages[0].id, thread: thread, depth: 0, size: 1, anyUnread: anyUnread, newestAt: messages[0].at))
                continue
            }
            let topID = Int64(thread.split(separator: ":").last.map(String.init) ?? "") ?? messages[0].id
            var children: [Int64: [ThreadInput]] = [:]
            for m in messages where m.id != topID {
                if let parent = parents[m.id] { children[parent, default: []].append(m) }
            }
            // Replies a loop of headers keeps out of reach of the first message go under it.
            var reachable: Set<Int64> = [topID]
            var queue = [topID]
            while let id = queue.popLast() {
                for child in children[id] ?? [] where reachable.insert(child.id).inserted { queue.append(child.id) }
            }
            children[topID, default: []].append(contentsOf: messages.filter { !reachable.contains($0.id) })
            for key in children.keys { children[key]?.sort { ($0.at, $0.id) < ($1.at, $1.id) } }

            result.append(ThreadedRow(
                id: topID, thread: thread, depth: 0, size: size, anyUnread: anyUnread, hasReplies: true,
                newestAt: messages.last!.at))
            guard expanded.contains(thread) else { continue }
            var placed: Set<Int64> = [topID]
            func walk(_ id: Int64, depth: Int) {
                for child in children[id] ?? [] where placed.insert(child.id).inserted {
                    let replies = (children[child.id] ?? []).contains { !placed.contains($0.id) }
                    result.append(ThreadedRow(
                        id: child.id, thread: thread, depth: depth, size: 1, anyUnread: false, hasReplies: replies,
                        newestAt: child.at))
                    if opened.contains(child.id) { walk(child.id, depth: depth + 1) }
                }
            }
            walk(topID, depth: 1)
        }
        return result
    }

    public func messageIDs(scope: MessageScope, sort: MessageSort = .newestFirst, search: String? = nil) throws
        -> [Int64]
    {
        let (filter, args) = self.filter(scope: scope, search: search)
        let sql = "SELECT m.id FROM message m WHERE \(filter) ORDER BY \(Self.orderBy(sort))"
        return try dbPool.read { db in try Int64.fetchAll(db, sql: sql, arguments: args) }
    }

    /// How many of a list's messages match `counting` (for Dock counters).
    public func count(scope: MessageScope, counting: MessageCount) throws -> Int {
        let (filter, args) = self.filter(scope: scope, search: nil)
        let condition: String
        switch counting {
        case .all: condition = ""
        case .unread: condition = " AND NOT m.isSeen"
        case .flagged: condition = " AND m.isFlagged"
        case .unreplied: condition = " AND NOT m.isAnswered AND NOT m.isDraft"
        }
        let sql = "SELECT COUNT(*) FROM message m WHERE \(filter)\(condition)"
        return try dbPool.read { db in try Int.fetchOne(db, sql: sql, arguments: args) ?? 0 }
    }

    /// Which of these messages are in a list.
    public func ids(_ ids: [Int64], in scope: MessageScope) throws -> Set<Int64> {
        guard !ids.isEmpty else { return [] }
        let (filter, args) = self.filter(scope: scope, search: nil)
        var arguments = args
        arguments += StatementArguments(ids)
        let sql = "SELECT m.id FROM message m WHERE \(filter) AND m.id IN (\(Self.placeholders(ids.count)))"
        return Set(try dbPool.read { db in try Int64.fetchAll(db, sql: sql, arguments: arguments) })
    }

    /// The most recently received message in a list, whatever the list's sort order.
    public func newestMessageID(scope: MessageScope, search: String? = nil) throws -> Int64? {
        let (filter, args) = self.filter(scope: scope, search: search)
        let sql = "SELECT m.id FROM message m WHERE \(filter) ORDER BY m.receivedAt DESC, m.id DESC LIMIT 1"
        return try dbPool.read { db in try Int64.fetchOne(db, sql: sql, arguments: args) }
    }

    /// WHERE clause (on a table aliased `m`) and arguments selecting a list's messages.
    func filter(scope: MessageScope, search: String?) -> (String, StatementArguments) {
        let (clause, args) = filterParts(scope: scope, search: search)
        return (clause, StatementArguments(args))
    }

    /// `filter`'s clause with its arguments as a list, to combine into larger queries (smart mailboxes).
    func filterParts(scope: MessageScope, search: String?) -> (String, [(any DatabaseValueConvertible)?]) {
        var clauses: [String] = []
        var args: [(any DatabaseValueConvertible)?] = []

        // A special mailbox's own list, or one of its submailboxes: narrowed by its conditions.
        if case .within(let parent, let child) = scope {
            var (clause, args) = filterParts(scope: child, search: search)
            if let (condition, conditionArgs) = specialFilter(key: parent) {
                clause = "(\(clause)) AND (\(condition))"
                args += conditionArgs
            }
            return (clause, args)
        }
        switch scope {
        case .allMessages:
            clauses.append("""
                NOT EXISTS (SELECT 1 FROM message_mailbox mm JOIN mailbox b ON b.id = mm.mailboxId
                            WHERE mm.messageId = m.id AND b.role IN ('trash', 'junk'))
                """)
        case .everything:
            clauses.append("1")
        case .role(let role):
            clauses.append("""
                m.id IN (SELECT mm.messageId FROM message_mailbox mm JOIN mailbox b ON b.id = mm.mailboxId
                         WHERE b.role = ?)
                """)
            args.append(role)
        case .flagged:
            clauses.append("m.isFlagged")
        case .mailbox(let id):
            clauses.append("m.id IN (SELECT messageId FROM message_mailbox WHERE mailboxId = ?)")
            args.append(id)
        case .account(let id):
            clauses.append("m.accountId = ?")
            args.append(id)
        case .flaggedInMailbox(let id):
            clauses.append("m.isFlagged AND m.id IN (SELECT messageId FROM message_mailbox WHERE mailboxId = ?)")
            args.append(id)
        case .flaggedInAccount(let id):
            clauses.append("m.isFlagged AND m.accountId = ?")
            args.append(id)
        case .allInAccount(let id):
            clauses.append("""
                m.accountId = ? AND NOT EXISTS (SELECT 1 FROM message_mailbox mm JOIN mailbox b ON b.id = mm.mailboxId
                                                WHERE mm.messageId = m.id AND b.role IN ('trash', 'junk'))
                """)
            args.append(id)
        case .smart(let id):
            let (clause, smartArgs) = smartFilter(id: id)
            clauses.append(clause)
            args += smartArgs
        case .smartValue(let id, let field, let value):
            let (clause, smartArgs) = smartFilter(id: id)
            let (test, testArgs) = Self.smartValueTest(field, value)
            clauses.append("\(clause) AND \(test)")
            args += smartArgs + testArgs
        case .smartAccountValue(let id, let accountId, let field, let value):
            let (clause, smartArgs) = smartFilter(id: id)
            let (test, testArgs) = Self.smartValueTest(field, value)
            clauses.append("\(clause) AND m.accountId = ? AND \(test)")
            args += smartArgs + [accountId] + testArgs
        case .within:
            break  // handled above
        case .smartAccount(let id, let accountId):
            let (clause, smartArgs) = smartFilter(id: id)
            clauses.append("\(clause) AND m.accountId = ?")
            args += smartArgs + [accountId]
        }

        switch scope {
        case .allMessages, .everything, .role:
            if let (condition, conditionArgs) = specialFilter(key: scope.key) {
                clauses.append("(\(condition))")
                args += conditionArgs
            }
        default: break
        }

        if let query = search.flatMap(Self.ftsQuery) {
            clauses.append("m.id IN (SELECT rowid FROM message_fts WHERE message_fts MATCH ?)")
            args.append(query)
        }

        return (clauses.joined(separator: " AND "), args)
    }

    public func rows(ids: [Int64]) throws -> [MessageRow] {
        guard !ids.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        return try dbPool.read { db in
            try MessageRow.fetchAll(
                db,
                sql: """
                    SELECT m.id, m.accountId, m.fromDisplay, m.fromEmail, m.subject, m.receivedAt, m.isSeen,
                           m.isFlagged, m.isAnswered, m.hasAttachment, m.size, a.name AS accountName,
                           (SELECT b.name FROM message_mailbox mm JOIN mailbox b ON b.id = mm.mailboxId
                            WHERE mm.messageId = m.id ORDER BY b.role IS NULL, b.name LIMIT 1) AS mailboxName
                    FROM message m JOIN account a ON a.id = m.accountId
                    WHERE m.id IN (\(marks))
                    """,
                arguments: StatementArguments(ids))
        }
    }

    public func detail(id: Int64) throws -> MessageDetail? {
        try dbPool.read { db in
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT accountId, remoteId, blobId, subject, receivedAt, sentAt FROM message WHERE id = ?",
                    arguments: [id])
            else { return nil }
            let addresses = try Row.fetchAll(
                db, sql: "SELECT role, name, email FROM address WHERE messageId = ? ORDER BY role, position",
                arguments: [id]
            ).compactMap { r -> IncomingMessage.Address? in
                guard let role = AddressRole(rawValue: r["role"]) else { return nil }
                return IncomingMessage.Address(role: role, name: r["name"], email: r["email"])
            }
            let sentAt: Double? = row["sentAt"]
            return MessageDetail(
                id: id, accountId: row["accountId"], remoteId: row["remoteId"], blobId: row["blobId"],
                subject: row["subject"], receivedAt: Date(timeIntervalSince1970: row["receivedAt"]),
                sentAt: sentAt.map(Date.init(timeIntervalSince1970:)), addresses: addresses)
        }
    }

    public func body(messageId: Int64) throws -> MessageBody? {
        try dbPool.read { db in
            try Row.fetchOne(db, sql: "SELECT html, text FROM message_body WHERE messageId = ?", arguments: [messageId])
                .map { MessageBody(html: $0["html"], text: $0["text"]) }
        }
    }

    // MARK: Correspondence

    /// The other party of a message: the sender, unless the user sent it, then the first recipient.
    public func correspondent(messageId: Int64, myAddresses: Set<String>) throws -> String? {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT role, email FROM address WHERE messageId = ? ORDER BY role, position",
                arguments: [messageId])
            let pairs = rows.map { (role: $0["role"] as Int, email: $0["email"] as String) }
            let from = pairs.first { $0.role == AddressRole.from.rawValue }?.email
            if let from, !myAddresses.contains(from) { return from }
            let recipientRoles = [AddressRole.to.rawValue, AddressRole.cc.rawValue, AddressRole.bcc.rawValue]
            return pairs.first { recipientRoles.contains($0.role) && !myAddresses.contains($0.email) }?.email ?? from
        }
    }

    /// Which of my addresses a message used: its sender if I sent it, else the first of mine among
    /// its recipients. Nil when none of mine appear (Bcc, mailing lists).
    public func myAddress(in messageId: Int64, myAddresses: Set<String>) throws -> String? {
        try dbPool.read { db in
            try String.fetchAll(
                db, sql: "SELECT email FROM address WHERE messageId = ? ORDER BY role, position", arguments: [messageId]
            ).first(where: myAddresses.contains)
        }
    }

    /// Messages from or to `email`, across all accounts and mailboxes: the newest `limit`, in `sort` order.
    /// With `mine`, only the ones that also involve that address of mine, so mail with the same person
    /// through my other addresses stays out.
    /// Mail exchanged with `email`, leaving out deleted messages (in Deleted Messages) as MailMate's
    /// Correspondence pane does, except `keeping` (the message it was opened for, wherever it is).
    public func correspondenceIDs(
        email: String, via mine: String? = nil, sort: MessageSort = .newestFirst, limit: Int = 2000, keeping: Int64? = nil
    ) throws -> [Int64] {
        try dbPool.read { db in
            let viaMine = mine == nil ? "" : " AND id IN (SELECT messageId FROM address WHERE email = ?)"
            var arguments: [any DatabaseValueConvertible] = [email.lowercased()]
            if let mine { arguments.append(mine.lowercased()) }
            arguments.append(keeping ?? -1)
            arguments.append(limit)
            return try Int64.fetchAll(
                db,
                sql: """
                    SELECT m.id FROM (
                        SELECT id, receivedAt, fromDisplay, sortSubject, size FROM message
                        WHERE id IN (SELECT messageId FROM address WHERE email = ?)\(viaMine)
                          AND (id = ? OR id NOT IN (
                            SELECT mm.messageId FROM message_mailbox mm JOIN mailbox b ON b.id = mm.mailboxId
                            WHERE b.role = 'trash'))
                        ORDER BY receivedAt DESC LIMIT ?
                    ) m
                    ORDER BY \(Self.orderBy(sort))
                    """,
                arguments: StatementArguments(arguments))
        }
    }

    // MARK: Counts

    public struct Counts: Sendable {
        public var unreadByRole: [String: Int] = [:]
        public var flagged = 0
        public var unreadByAccount: [String: Int] = [:]
        public var flaggedByMailbox: [Int64: Int] = [:]
        public var flaggedByAccount: [String: Int] = [:]
        /// Mailboxes holding mail outside Trash and Junk (sources for All Messages).
        public var mailboxesWithMail: Set<Int64> = []

        public init() {}
    }

    /// Badge counts. `flaggedByMailbox`, which reads every flagged message, only when Flagged is split
    /// by source mailbox.
    public func counts(flaggedByMailbox needsFlaggedByMailbox: Bool = false) throws -> Counts {
        try dbPool.read { db in
            var c = Counts()
            for row in try Row.fetchAll(
                db, sql: "SELECT role, SUM(unreadEmails) AS n FROM mailbox WHERE role IS NOT NULL GROUP BY role")
            {
                c.unreadByRole[row["role"]] = row["n"]
            }
            for row in try Row.fetchAll(
                db, sql: "SELECT accountId, SUM(unreadEmails) AS n FROM mailbox WHERE role = 'inbox' GROUP BY accountId")
            {
                c.unreadByAccount[row["accountId"]] = row["n"]
            }
            c.flagged = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message WHERE isFlagged") ?? 0
            if needsFlaggedByMailbox {
                for row in try Row.fetchAll(
                    db,
                    sql: """
                        SELECT mm.mailboxId, COUNT(*) AS n FROM message m JOIN message_mailbox mm ON mm.messageId = m.id
                        WHERE m.isFlagged GROUP BY mm.mailboxId
                        """)
                {
                    c.flaggedByMailbox[row["mailboxId"]] = row["n"]
                }
            }
            for row in try Row.fetchAll(db, sql: "SELECT accountId, COUNT(*) AS n FROM message WHERE isFlagged GROUP BY accountId") {
                c.flaggedByAccount[row["accountId"]] = row["n"]
            }
            c.mailboxesWithMail = Set(try Int64.fetchAll(
                db, sql: "SELECT id FROM mailbox WHERE totalEmails > 0 AND (role IS NULL OR role NOT IN ('trash', 'junk'))"))
            return c
        }
    }

    // MARK: Observation

    /// Calls `onChange` after every committed transaction that touches messages, mailboxes or accounts.
    /// Called on a background queue; the caller is expected to debounce and hop to the main thread.
    public func observeChanges(_ onChange: @escaping @Sendable () -> Void) -> StoreObservation {
        // Only the message columns the UI shows: download bookkeeping (`downloadState`), bodies and the
        // search index change constantly during a full download and must not refresh the UI.
        let shown = Table("message").select(
            Column("accountId"), Column("subject"), Column("fromDisplay"), Column("fromEmail"), Column("receivedAt"),
            Column("isSeen"), Column("isFlagged"), Column("isAnswered"), Column("hasAttachment"), Column("size"))
        let observation = DatabaseRegionObservation(
            tracking: shown, Table("message_mailbox"), Table("mailbox"), Table("account"), Table("smart_mailbox"))
        let cancellable = observation.start(in: dbPool, onError: { _ in }, onChange: { _ in onChange() })
        return StoreObservation(cancellable)
    }

    // MARK: Helpers

    /// ORDER BY terms for `sort`, on a table aliased `m`.
    static func orderBy(_ sort: MessageSort) -> String {
        let direction = sort.ascending ? "ASC" : "DESC"
        return switch sort.key {
        case .receivedAt: "m.receivedAt \(direction), m.id \(direction)"
        case .from: "m.fromDisplay COLLATE NOCASE \(direction), m.receivedAt DESC"
        case .subject: "m.sortSubject \(direction), m.receivedAt DESC"
        case .size: "m.size \(direction), m.receivedAt DESC"
        }
    }

    static func sortSubject(_ subject: String) -> String {
        var s = Substring(subject)
        let pattern = /^\s*(?i:re|fwd?|aw|sv|wg|tr)\s*(\[\d+\])?\s*:\s*/
        while let match = s.prefixMatch(of: pattern) { s = s[match.range.upperBound...] }
        return s.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Turns free text into an FTS5 query: every word must match, as a prefix.
    static func ftsQuery(_ text: String) -> String? {
        let tokens = text.split(whereSeparator: \.isWhitespace).map {
            "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*"
        }
        return tokens.isEmpty ? nil : tokens.joined(separator: " ")
    }
}

public final class StoreObservation: @unchecked Sendable {
    private let cancellable: AnyDatabaseCancellable

    init(_ cancellable: AnyDatabaseCancellable) { self.cancellable = cancellable }

    public func cancel() { cancellable.cancel() }
}

extension Array {
    func chunked(_ size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}
