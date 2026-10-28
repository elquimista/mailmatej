import Foundation
import GRDB

/// A mailbox's rule, as MailMate's: actions applied to new messages arriving in the mailbox that meet
/// its conditions. Rules run in order; unchecked rules and actions are skipped.
public struct RuleRecord: Hashable, Sendable {
    public var id: Int64
    /// The rule this is a subrule of (it runs on the messages that rule matched).
    public var parentId: Int64?
    /// The mailbox it belongs to: a `MessageScope` key ("role:inbox", "smart:3", "mailbox:42", ...).
    public var mailboxKey: String
    public var sortOrder: Int
    public var definition: RuleDefinition
}

public struct RuleDefinition: Codable, Hashable, Sendable {
    public var enabled = true
    /// MailMate's "Description".
    public var name = "Untitled"
    public var condition = SmartCondition.compound(.all, [])
    public var actions: [RuleAction] = []

    public init(enabled: Bool = true, name: String = "Untitled", condition: SmartCondition = .compound(.all, []), actions: [RuleAction] = []) {
        self.enabled = enabled
        self.name = name
        self.condition = condition
        self.actions = actions
    }
}

public struct RuleAction: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case move, copy, delete, deletePermanently, redirect, forward, setKeyword, removeKeyword
        /// No longer offered (MailMate has neither); kept so saved rules still run.
        case archive, junk

        /// MailMate's action menu, in its groups (without Export, Play Sound and Run Command).
        public static let menuGroups: [[Kind]] = [[.move, .copy], [.delete, .deletePermanently], [.redirect, .forward], [.setKeyword, .removeKeyword]]

        public var title: String {
            switch self {
            case .move: "Move to Mailbox"
            case .copy: "Copy to Mailbox"
            case .delete: "Delete"
            case .deletePermanently: "Delete Permanently"
            case .redirect: "Redirect"
            case .forward: "Forward"
            case .setKeyword: "Set Tag/Keyword"
            case .removeKeyword: "Remove Tag/Keyword"
            case .archive: "Archive"
            case .junk: "Move to Junk"
            }
        }

        /// What its value is: a mailbox id, an address, or a keyword.
        public enum Value { case none, mailbox, address, keyword }

        public var value: Value {
            switch self {
            case .move, .copy: .mailbox
            case .redirect, .forward: .address
            case .setKeyword, .removeKeyword: .keyword
            default: .none
            }
        }

        public var takesValue: Bool { value != .none }

        /// Moving actions end where a message is, so they run after the others.
        public var moves: Bool { [.move, .delete, .deletePermanently, .archive, .junk].contains(self) }
    }

    public var enabled = true
    public var kind: Kind
    /// A keyword ("$seen", "$flagged"), an address (Redirect, Forward), or a mailbox's id (Move, Copy).
    public var value = ""

    public init(enabled: Bool = true, kind: Kind, value: String = "") {
        self.enabled = enabled
        self.kind = kind
        self.value = value
    }
}

/// The Standard keywords of Set/Remove Tag/Keyword, as MailMate lists and names them.
public enum RuleKeyword: String, CaseIterable, Sendable {
    case seen = "$seen", flagged = "$flagged", draft = "$draft", answered = "$answered", forwarded = "$forwarded"
    case muted = "$muted", junk = "$junk", notJunk = "$notjunk"

    public var title: String {
        switch self {
        case .seen: "Seen (Read)"
        case .flagged: "Flagged"
        case .draft: "Draft"
        case .answered: "Answered"
        case .forwarded: "Forwarded"
        case .muted: "Muted"
        case .junk: "Junk"
        case .notJunk: "Not junk"
        }
    }
}

extension MailStore {
    public func rules(mailboxKey: String? = nil) throws -> [RuleRecord] {
        try dbPool.read { db in
            let rows = try mailboxKey.map {
                try Row.fetchAll(db, sql: "SELECT * FROM rule WHERE mailboxKey = ? ORDER BY sortOrder, id", arguments: [$0])
            } ?? Row.fetchAll(db, sql: "SELECT * FROM rule ORDER BY mailboxKey, sortOrder, id")
            return rows.map { row in
                let json: String = row["definition"]
                return RuleRecord(
                    id: row["id"], parentId: row["parentId"], mailboxKey: row["mailboxKey"], sortOrder: row["sortOrder"],
                    definition: (try? JSONDecoder().decode(RuleDefinition.self, from: Data(json.utf8))) ?? RuleDefinition())
            }
        }
    }

    /// A new rule at the end of the mailbox's rules (or of `parentId`'s subrules).
    public func createRule(mailboxKey: String, parentId: Int64? = nil, definition: RuleDefinition = RuleDefinition()) throws -> Int64 {
        let json = String(decoding: try JSONEncoder().encode(definition), as: UTF8.self)
        return try write { db in
            let order = try Int.fetchOne(
                db, sql: "SELECT coalesce(max(sortOrder), -1) + 1 FROM rule WHERE mailboxKey = ? AND parentId IS ?",
                arguments: [mailboxKey, parentId]) ?? 0
            try db.execute(
                sql: "INSERT INTO rule (mailboxKey, parentId, sortOrder, definition) VALUES (?, ?, ?, ?)",
                arguments: [mailboxKey, parentId, order, json])
            return db.lastInsertedRowID
        }
    }

    /// Copies a rule and its subrules, the copy right after it.
    public func duplicateRule(id: Int64) throws -> Int64? {
        let all = try rules()
        guard let original = all.first(where: { $0.id == id }) else { return nil }
        func copy(_ rule: RuleRecord, under parent: Int64?, rename: Bool) throws -> Int64 {
            var definition = rule.definition
            if rename { definition.name += definition.name.isEmpty ? "" : " copy" }
            let new = try createRule(mailboxKey: rule.mailboxKey, parentId: parent, definition: definition)
            for child in all where child.parentId == rule.id { _ = try copy(child, under: new, rename: false) }
            return new
        }
        let new = try copy(original, under: original.parentId, rename: true)
        // Right after the original: shift the later siblings.
        try write { db in
            try db.execute(
                sql: "UPDATE rule SET sortOrder = sortOrder + 1 WHERE mailboxKey = ? AND parentId IS ? AND sortOrder > ? AND id <> ?",
                arguments: [original.mailboxKey, original.parentId, original.sortOrder, new])
            try db.execute(sql: "UPDATE rule SET sortOrder = ? WHERE id = ?", arguments: [original.sortOrder + 1, new])
        }
        return new
    }

    public func updateRule(id: Int64, definition: RuleDefinition) throws {
        let json = String(decoding: try JSONEncoder().encode(definition), as: UTF8.self)
        try write { db in try db.execute(sql: "UPDATE rule SET definition = ? WHERE id = ?", arguments: [json, id]) }
    }

    /// Deletes a rule and its subrules.
    public func deleteRule(id: Int64) throws {
        try write { db in try db.execute(sql: "DELETE FROM rule WHERE id = ?", arguments: [id]) }
    }

    /// Of `messageIds`, those in the rule's mailbox that meet its conditions.
    public func messages(_ messageIds: [Int64], matching rule: RuleRecord) throws -> [Int64] {
        guard !messageIds.isEmpty, let scope = MessageScope(key: rule.mailboxKey) else { return [] }
        let (inMailbox, mailboxArgs) = filterParts(scope: scope, search: nil)
        let (condition, conditionArgs) = sql(rule.definition.condition)
        let marks = Array(repeating: "?", count: messageIds.count).joined(separator: ", ")
        let query = "SELECT m.id FROM message m WHERE m.id IN (\(marks)) AND (\(inMailbox)) AND (\(condition))"
        let args: [(any DatabaseValueConvertible)?] = messageIds.map { $0 } + mailboxArgs + conditionArgs
        return try dbPool.read { db in try Int64.fetchAll(db, sql: query, arguments: StatementArguments(args)) }
    }

    /// The keywords on any message other than the standard ones (MailMate's "Other"), A to Z with
    /// symbols first, as MailMate sorts them.
    public func otherKeywords() throws -> [String] {
        let standard = Set(RuleKeyword.allCases.map(\.rawValue))
        let all = try dbPool.read { db in try String.fetchAll(db, sql: "SELECT DISTINCT keyword FROM message_keyword") }
        return all.filter { !standard.contains($0.lowercased()) }.sorted { $0.lowercased() < $1.lowercased() }
    }

    /// Local ids of an account's messages, by their remote ids.
    public func messageIDsByRemoteID(accountId: String, remoteIds: [String]) throws -> [String: Int64] {
        guard !remoteIds.isEmpty else { return [:] }
        return try dbPool.read { db in
            var ids: [String: Int64] = [:]
            for chunk in remoteIds.chunked(500) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                for row in try Row.fetchAll(
                    db, sql: "SELECT remoteId, id FROM message WHERE accountId = ? AND remoteId IN (\(marks))",
                    arguments: StatementArguments([accountId] + chunk))
                {
                    ids[row["remoteId"]] = row["id"]
                }
            }
            return ids
        }
    }

    /// Local ids of an account's messages by remote id.
    public func messageIDs(accountId: String, remoteIds: [String]) throws -> [Int64] {
        guard !remoteIds.isEmpty else { return [] }
        return try dbPool.read { db in
            var ids: [Int64] = []
            for chunk in remoteIds.chunked(500) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                ids += try Int64.fetchAll(
                    db, sql: "SELECT id FROM message WHERE accountId = ? AND remoteId IN (\(marks))",
                    arguments: StatementArguments([accountId] + chunk))
            }
            return ids
        }
    }
}
