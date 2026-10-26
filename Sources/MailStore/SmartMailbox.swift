import Foundation
import GRDB

/// A smart mailbox, as MailMate's: messages of some mailboxes (Mailboxes tab) that meet a tree of
/// conditions (Conditions tab), optionally split into submailboxes (Submailboxes tab). Lists and counts
/// compile the definition to SQL, so membership is always current.
public struct SmartMailboxRecord: Hashable, Sendable {
    public var id: Int64
    public var parentId: Int64?
    /// The special mailbox it's inside ("all", "role:inbox"), for a top-level smart mailbox.
    public var parentKey: String?
    public var name: String
    public var sortOrder: Int
    public var definition: SmartDefinition

    public init(id: Int64, parentId: Int64?, parentKey: String? = nil, name: String, sortOrder: Int, definition: SmartDefinition) {
        self.id = id
        self.parentId = parentId
        self.parentKey = parentKey
        self.name = name
        self.sortOrder = sortOrder
        self.definition = definition
    }
}

public struct SmartDefinition: Codable, Hashable, Sendable {
    public var sources = SmartSources()
    /// The root of the Conditions tab: All (or Any) of its rows; with no rows, every message matches.
    public var condition = SmartCondition.compound(.all, [])
    public var split = SmartSplit()
    /// Its own icon (an SF Symbol name), when not the smart mailbox default: Flagged's flag.
    public var icon: String?

    public init(
        sources: SmartSources = SmartSources(), condition: SmartCondition = .compound(.all, []), split: SmartSplit = SmartSplit(),
        icon: String? = nil
    ) {
        self.sources = sources
        self.condition = condition
        self.split = split
        self.icon = icon
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sources = try c.decodeIfPresent(SmartSources.self, forKey: .sources) ?? SmartSources()
        condition = try c.decodeIfPresent(SmartCondition.self, forKey: .condition) ?? .compound(.all, [])
        split = try c.decodeIfPresent(SmartSplit.self, forKey: .split) ?? SmartSplit()
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
    }
}

public enum SmartMatch: String, Codable, Hashable, Sendable, CaseIterable {
    /// MailMate's choices, in its order: any row true, every row true, no row true.
    case any, all, none
    public var title: String {
        switch self {
        case .any: "Any"
        case .all: "All"
        case .none: "None"
        }
    }
}

/// The Mailboxes tab: "Any/All of the following mailboxes", a tree like the conditions whose rows are
/// `.rule(.mailbox, .is, key)` with `MessageScope` keys ("all", "role:inbox", "mailbox:42", "smart:7").
public struct SmartSources: Codable, Hashable, Sendable {
    public var root: SmartCondition
    /// "Include messages in any submailboxes of this mailbox": the smart mailboxes inside this one add
    /// their messages to its own (MailMate offers it only when the Submailboxes tab splits nothing).
    public var includeSubmailboxes = false

    public init(scopes: [String] = ["all"], match: SmartMatch = .any, includeSubmailboxes: Bool = false) {
        root = .compound(match, scopes.map { .rule(.mailbox, .is, $0) })
        self.includeSubmailboxes = includeSubmailboxes
    }

    public init(root: SmartCondition, includeSubmailboxes: Bool = false) {
        self.root = root
        self.includeSubmailboxes = includeSubmailboxes
    }

    /// The scope keys named anywhere in the tree.
    public var scopes: [String] {
        func keys(_ c: SmartCondition) -> [String] {
            switch c {
            case .compound(_, let children, _): children.flatMap(keys)
            case .rule(_, _, let value, _, _): [value]
            }
        }
        return keys(root)
    }
}

/// The Submailboxes tab: a child for each value of a field among the messages, and/or each account.
public struct SmartSplit: Codable, Hashable, Sendable {
    public var byValue = false
    public var field = SmartField.fromName
    public var unlessOnlyOne = true
    public var byAccount = false

    public init() {}

    public var splits: Bool { byValue || byAccount }

}

/// A row of the Conditions tab: a compound (All/Any of its rows) or a field test. Each row has
/// MailMate's checkbox: an unchecked row is ignored.
public indirect enum SmartCondition: Hashable, Sendable {
    case compound(SmartMatch, [SmartCondition], enabled: Bool = true)
    case rule(SmartField, SmartOperator, String, enabled: Bool = true, options: SmartOptions = [])

    public var isEnabled: Bool {
        switch self {
        case .compound(_, _, let enabled), .rule(_, _, _, let enabled, _): enabled
        }
    }
}

extension SmartCondition: Codable {
    private enum CodingKeys: String, CodingKey { case match, children, field, op, value, enabled, options }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        if let children = try c.decodeIfPresent([SmartCondition].self, forKey: .children) {
            self = .compound(try c.decodeIfPresent(SmartMatch.self, forKey: .match) ?? .all, children, enabled: enabled)
        } else {
            self = .rule(
                try c.decode(SmartField.self, forKey: .field), try c.decode(SmartOperator.self, forKey: .op),
                try c.decodeIfPresent(String.self, forKey: .value) ?? "", enabled: enabled,
                options: SmartOptions(rawValue: try c.decodeIfPresent(Int.self, forKey: .options) ?? 0))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .compound(let match, let children, let enabled):
            try c.encode(match, forKey: .match)
            try c.encode(children, forKey: .children)
            if !enabled { try c.encode(false, forKey: .enabled) }
        case .rule(let field, let op, let value, let enabled, let options):
            try c.encode(field, forKey: .field)
            try c.encode(op, forKey: .op)
            try c.encode(value, forKey: .value)
            if !enabled { try c.encode(false, forKey: .enabled) }
            if !options.isEmpty { try c.encode(options.rawValue, forKey: .options) }
        }
    }
}

/// What a condition tests, named as MailMate's field menu: "from.domain" is From ‣ Domain. Address
/// fields test each address in their headers (any one matching).
public struct SmartField: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public static func address(_ header: AddressHeader, _ part: AddressPart) -> SmartField {
        SmartField(rawValue: "\(header.rawValue).\(part.rawValue)")
    }

    public static let fromName = address(.from, .name), fromAddress = address(.from, .address), fromDomain = address(.from, .domain)
    public static let toName = address(.to, .name), toAddress = address(.to, .address), toDomain = address(.to, .domain)
    public static let subject = SmartField(rawValue: "subject")
    /// The message's whole text, quotes included ("Message Text", from before Unquoted Text; no longer
    /// offered, kept for the conditions that use it).
    public static let body = SmartField(rawValue: "body")
    /// MailMate's "Unquoted Text": what the sender wrote, without what the message quotes.
    public static let unquoted = SmartField(rawValue: "unquoted")
    /// MailMate's "Quoted Text": only what the message quotes.
    public static let quoted = SmartField(rawValue: "quoted")
    /// MailMate's "Common Headers or Unquoted Text": subject, addresses or unquoted text.
    public static let headersOrUnquoted = SmartField(rawValue: "headersOrUnquoted")
    /// MailMate's "Common Headers or Text": subject, addresses or text.
    public static let headersOrText = SmartField(rawValue: "headersOrText")

    /// Fields matched in the search index (words, not exact strings): contains or doesn't.
    public var isFullText: Bool { [.body, .unquoted, .quoted, .headersOrUnquoted, .headersOrText].contains(self) }
    public static let filename = SmartField(rawValue: "filename")
    public static let keyword = SmartField(rawValue: "keyword")
    /// "Message is ▸ Unread" (op `is`) or "Message is not ▸ …".
    public static let status = SmartField(rawValue: "status")
    /// MailMate's Date (No Specifier). Here it's when the message arrived: what filtering by date nearly
    /// always means ("new this week", "older than a year"), and what MailMate's own recent-mail mailbox
    /// tests. The Date header the sender's mail app wrote can be off (delays, send later, backdating).
    public static let date = SmartField(rawValue: "date")
    /// MailMate's Date ▸ » Local ▸ No Specifier: the same date, in this Mac's time zone (as the date
    /// comparisons already are).
    public static let dateLocal = SmartField(rawValue: "date.local")
    public static let received = SmartField(rawValue: "received")
    public static let sent = SmartField(rawValue: "sent")
    public static let mailbox = SmartField(rawValue: "mailbox")
    public static let account = SmartField(rawValue: "account")

    /// MailMate's Date ▸ Day, Formatted, …: pieces of the date (its arrival) written "2026-10-26 09:27:08
    /// +0200", in the sender's time zone (» Local ▸: in this Mac's), matched as text.
    public enum DatePart: String, CaseIterable, Sendable {
        case day, formatted, hour, month, time, year, zone

        public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    public static func datePart(_ part: DatePart, local: Bool) -> SmartField {
        SmartField(rawValue: local ? "date.local.\(part.rawValue)" : "date.\(part.rawValue)")
    }

    /// The date part this field matches, and whether in this Mac's time zone.
    public var datePart: (part: DatePart, local: Bool)? {
        let parts = rawValue.split(separator: ".").map(String.init)
        guard parts.first == "date", parts.count == 2 || (parts.count == 3 && parts[1] == "local"),
            let part = DatePart(rawValue: parts[parts.count - 1])
        else { return nil }
        return (part, parts.count == 3)
    }

    public enum AddressHeader: String, CaseIterable, Sendable {
        case from, recipient, to, cc, bcc, any

        public var title: String {
            switch self {
            case .from: "From"
            case .recipient: "Recipient (To, Cc, Bcc)"
            case .to: "To"
            case .cc: "Cc"
            case .bcc: "Bcc"
            case .any: "Any Address"
            }
        }

        var roles: [AddressRole] {
            switch self {
            case .from: [.from]
            case .recipient: [.to, .cc, .bcc]
            case .to: [.to]
            case .cc: [.cc]
            case .bcc: [.bcc]
            case .any: [.from, .sender, .to, .cc, .bcc, .replyTo]
            }
        }
    }

    /// The part of each address tested, in MailMate's submenu order.
    public enum AddressPart: String, CaseIterable, Sendable {
        case all, address, domain, name, second, third, top, user
        /// Name ▸ First and Last: its first and last words.
        case firstName, lastName

        /// The parts in a header's submenu (First and Last are inside Name).
        public static let menuOrder: [AddressPart] = [.all, .address, .domain, .name, .second, .third, .top, .user]

        public var title: String {
            switch self {
            case .all: "No Specifier"
            case .address: "Address"
            case .domain: "Domain"
            case .name: "Name"
            case .firstName: "First"
            case .lastName: "Last"
            case .second: "Second-Level"
            case .third: "Third-Level"
            case .top: "Top-Level"
            case .user: "User"
            }
        }

        /// The SQL for this part of an address row `a` (domain levels via `mmj_domain_level`).
        var column: String {
            switch self {
            case .all, .address: "a.email"
            case .name: "coalesce(a.name, '')"
            case .domain: "substr(a.email, instr(a.email, '@') + 1)"
            case .user: "substr(a.email, 1, instr(a.email, '@') - 1)"
            case .top: "mmj_domain_level(a.email, 1)"
            case .second: "mmj_domain_level(a.email, 2)"
            case .third: "mmj_domain_level(a.email, 3)"
            case .firstName: "mmj_name_word(coalesce(a.name, ''), 0)"
            case .lastName: "mmj_name_word(coalesce(a.name, ''), 1)"
            }
        }

        /// The whole address as a header shows it, "Ellie Brown <ellie@x.com>" (No Specifier's values).
        static let display = "CASE WHEN coalesce(a.name, '') = '' OR a.name = a.email THEN a.email ELSE a.name || ' <' || a.email || '>' END"

        var isName: Bool { self == .name || self == .firstName || self == .lastName }

        /// "Name ‣ First" for the pop-up's title.
        var path: String {
            switch self {
            case .firstName, .lastName: "Name \u{2023} \(title)"
            default: title
            }
        }
    }

    public enum Kind: Sendable { case text, status, days, mailbox, account }

    public var kind: Kind {
        switch self {
        case .status: .status
        case .date, .dateLocal, .received, .sent: .days
        case .mailbox: .mailbox
        case .account: .account
        default: .text
        }
    }

    /// The header and part of each address tested, for address fields.
    public var address: (header: AddressHeader, part: AddressPart)? {
        let parts = rawValue.split(separator: ".").map(String.init)
        guard parts.count == 2, let header = AddressHeader(rawValue: parts[0]), let part = AddressPart(rawValue: parts[1])
        else { return nil }
        return (header, part)
    }

    /// The pop-up's title, as MailMate writes nested fields: "From ‣ Domain" ("From" with No Specifier).
    public var title: String {
        if let (header, part) = address {
            let short = header == .recipient ? "Recipient" : header.title
            return part == .all ? short : "\(short) \u{2023} \(part.path)"
        }
        switch self {
        case .subject: return "Subject"
        case .body: return "Message Text"
        case .unquoted: return "Unquoted Text"
        case .quoted: return "Quoted Text"
        case .headersOrUnquoted: return "Common Headers or Unquoted Text"
        case .headersOrText: return "Common Headers or Text"
        case .filename: return "Filename"
        case .keyword: return "Tags/Keywords"
        case .status: return "Message is"  // with its status: "Message is Read"
        case .date: return "Date"
        case .dateLocal: return "Date \u{2023} Local"
        case .received: return "Date \u{2023} Received"
        case .sent: return "Date \u{2023} Sent"
        case .mailbox: return "Source \u{2023} Mailbox"
        case .account: return "Source"  // » Source's No Specifier
        default:
            if let (part, local) = datePart { return "Date \u{2023} \(local ? "Local \u{2023} " : "")\(part.title)" }
            return rawValue
        }
    }

    public var operators: [SmartOperator] {
        switch kind {
        case .text where isFullText: [.contains, .doesNotContain]
        // MailMate's operator menu, in its groups (see `operatorGroups`).
        case .text: [.is, .isNot, .contains, .doesNotContain, .lessOrEqual, .moreOrEqual, .isIn, .isNotIn, .exists, .notExists]
        case .status, .mailbox, .account: [.is, .isNot]
        case .days: [.withinLast, .notWithinLast, .isExactly, .isBefore, .isAfter, .exists, .notExists]
        }
    }

    /// The operators in MailMate's groups (separated in its menu).
    public var operatorGroups: [[SmartOperator]] {
        let ops = operators
        let groups: [[SmartOperator]] = [
            [.is, .isNot, .contains, .doesNotContain, .lessOrEqual, .moreOrEqual], [.isIn, .isNotIn],
            [.withinLast, .notWithinLast, .isExactly, .isBefore, .isAfter], [.exists, .notExists],
        ]
        return groups.map { $0.filter(ops.contains) }.filter { !$0.isEmpty }
    }

    /// Fields a smart mailbox can be split by (Submailboxes tab).
    public static let splitFields: [SmartField] = [
        .fromName, .fromAddress, .fromDomain, .toName, .toAddress, .toDomain, .subject,
    ]
}

public enum SmartOperator: String, Codable, Hashable, Sendable {
    case `is`, isNot, contains, doesNotContain, lessOrEqual, moreOrEqual, isIn, isNotIn, exists, notExists
    case withinLast, notWithinLast
    /// Dates: in, before or after a year, month or day ("2024", "2024-03", "2024-03-01").
    case isExactly, isBefore, isAfter
    /// No longer offered (MailMate has none); kept so saved conditions still read.
    case beginsWith, endsWith

    public var title: String {
        switch self {
        case .is: "is"
        case .isNot: "is not"
        case .contains: "contains"
        case .doesNotContain: "does not contain"
        case .lessOrEqual: "less or equal to"
        case .moreOrEqual: "more or equal to"
        case .isIn: "is in"
        case .isNotIn: "is not in"
        case .exists: "exists"
        case .notExists: "does not exist"
        case .withinLast: "is within last"
        case .notWithinLast: "is not within last"
        case .isExactly: "is exactly"
        case .isBefore: "is before"
        case .isAfter: "is after"
        case .beginsWith: "begins with"
        case .endsWith: "ends with"
        }
    }

    var isNegative: Bool { [.isNot, .doesNotContain, .isNotIn, .notExists, .notWithinLast].contains(self) }

    /// Tests that take no value ("exists").
    public var takesValue: Bool { self != .exists && self != .notExists }
}

/// A condition's Options (MailMate's operator menu): match case exactly; search all body parts.
public struct SmartOptions: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let caseSensitive = SmartOptions(rawValue: 1)
    /// Our text search already covers every part; kept for MailMate's menu.
    public static let allBodyParts = SmartOptions(rawValue: 2)
}

/// Values of the Status field.
public enum SmartStatus: String, CaseIterable, Sendable {
    case read, unread, flagged, replied, attachment, draft

    public var title: String {
        switch self {
        case .read: "Read"
        case .unread: "Unread"
        case .flagged: "Flagged"
        case .replied: "Replied"
        case .attachment: "With Attachment"
        case .draft: "Draft"
        }
    }

    var sql: String {
        switch self {
        case .read: "m.isSeen"
        case .unread: "NOT m.isSeen"
        case .flagged: "m.isFlagged"
        case .replied: "m.isAnswered"
        case .attachment: "m.hasAttachment"
        case .draft: "m.isDraft"
        }
    }
}

// MARK: - SQL

/// The smart mailboxes a store's lists and counts resolve against (reloaded whenever they change).
final class SmartCatalog: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [Int64: SmartMailboxRecord] = [:]
    private var special: [String: SmartCondition] = [:]
    /// Special mailboxes placed inside smart ones: their scope keys by smart mailbox, in order.
    private var placed: [Int64: [String]] = [:]

    func setPlaced(_ placements: [Int64: [String]]) { lock.withLock { placed = placements } }
    func placed(in id: Int64) -> [String] { lock.withLock { placed[id] ?? [] } }

    /// The conditions narrowing special mailboxes, by scope key.
    func setSpecial(_ conditions: [String: SmartCondition]) { lock.withLock { special = conditions } }
    func special(_ key: String) -> SmartCondition? { lock.withLock { special[key] } }

    func set(_ list: [SmartMailboxRecord]) {
        lock.withLock { records = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) }) }
    }

    subscript(id: Int64) -> SmartMailboxRecord? { lock.withLock { records[id] } }

    func children(of id: Int64) -> [SmartMailboxRecord] {
        lock.withLock { records.values.filter { $0.parentId == id }.sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) } }
    }
}

extension MailStore {
    /// WHERE clause (on `m`) for smart mailbox `id`: its sources, then its conditions, and with "Include
    /// messages in any submailboxes" also whatever its submailboxes show. `visited` guards against smart
    /// mailboxes that use each other as sources.
    func smartFilter(id: Int64, visited: Set<Int64> = []) -> (String, [(any DatabaseValueConvertible)?]) {
        guard let smart = smartCatalog[id], !visited.contains(id) else { return ("0", []) }
        let inside = visited.union([id])
        // No mailboxes added (MailMate's new smart mailbox) means no messages: "All Messages" is a choice
        // of its own. With "Include messages in any submailboxes" its submailboxes' still show.
        let (sources, sourceArgs) = Self.isEmpty(smart.definition.sources.root)
            ? ("0", []) : sql(smart.definition.sources.root, visited: inside)
        let (condition, conditionArgs) = sql(smart.definition.condition, visited: inside)
        var clause = "(\(sources)) AND (\(condition))"
        var args = sourceArgs + conditionArgs
        if smart.definition.sources.includeSubmailboxes {
            for child in smartCatalog.children(of: id) {
                let (childClause, childArgs) = smartFilter(id: child.id, visited: inside)
                clause = "(\(clause)) OR (\(childClause))"
                args += childArgs
            }
            // Special mailboxes placed inside it are its submailboxes too.
            for key in smartCatalog.placed(in: id) {
                guard let scope = MessageScope(key: key) else { continue }
                let (childClause, childArgs) = filterParts(scope: scope, search: nil)
                clause = "(\(clause)) OR (\(childClause))"
                args += childArgs
            }
        }
        return (clause, args)
    }

    static func isEmpty(_ condition: SmartCondition) -> Bool {
        if case .compound(_, let children, _) = condition { return children.allSatisfy(isEmpty) }
        return false
    }

    private func sourceFilter(_ scope: MessageScope, visited: Set<Int64>) -> (String, [(any DatabaseValueConvertible)?]) {
        if case .smart(let id) = scope { return smartFilter(id: id, visited: visited) }
        return filterParts(scope: scope, search: nil)
    }

    /// The test a by-value submailbox adds: the field's value is `value` (as `smartValues` lists them).
    static func smartValueTest(_ field: SmartField, _ value: String) -> (String, [(any DatabaseValueConvertible)?]) {
        guard let split = splitSource(field) else { return ("0", []) }
        if value.isEmpty, let (_, part) = field.address, part.isName {
            // "Other": the addresses without a name.
            return ("EXISTS (SELECT 1 FROM \(split.table!) WHERE \(split.link) AND \(split.filter) AND \(split.column) = '')", [])
        }
        guard let table = split.table else { return ("lower(\(split.column)) = lower(?)", [value]) }
        return ("EXISTS (SELECT 1 FROM \(table) WHERE \(split.link) AND \(split.filter) AND lower(\(split.column)) = lower(?))", [value])
    }

    /// Fields a smart mailbox can be split by: the text fields with values of their own (not text
    /// search), and » Source ▸ Mailbox ("Inbox – Alice") or Account.
    public static func canSplit(by field: SmartField) -> Bool { splitSource(field) != nil }

    /// Where a split's values come from: a joined table (or the message itself), and the value column.
    private static func splitSource(_ field: SmartField) -> (table: String?, link: String, filter: String, column: String)? {
        if let (header, part) = field.address {
            let roles = header.roles.map { String($0.rawValue) }.joined(separator: ", ")
            let column = part == .all ? SmartField.AddressPart.display : valueColumn(part)
            return ("address a", "a.messageId = m.id", "a.role IN (\(roles)) AND a.email <> ''", column)
        }
        switch field {
        case .subject: return (nil, "", "1", "m.subject")
        case .filename: return ("message_part p", "p.messageId = m.id", "p.name IS NOT NULL AND p.name <> ''", "p.name")
        case .keyword: return ("message_keyword k", "k.messageId = m.id", "1", "k.keyword")
        case .mailbox:
            return ("message_mailbox mm JOIN mailbox b ON b.id = mm.mailboxId JOIN account ac ON ac.id = b.accountId",
                    "mm.messageId = m.id", "1", "b.name || ' \u{2013} ' || ac.name")
        case .account: return ("account ac", "ac.id = m.accountId", "1", "ac.name")
        default: return nil
        }
    }

    /// An address part as submailboxes split by it. For names, addresses without one (or whose name
    /// is the address again) give "" — MailMate's "Other".
    static func valueColumn(_ part: SmartField.AddressPart) -> String {
        guard part.isName else { return part.column }
        return "CASE WHEN coalesce(a.name, '') = '' OR lower(a.name) = a.email THEN '' ELSE \(part.column) END"
    }

    /// SQL for one condition row (true when it's unchecked, so it doesn't count); `visited` is the
    /// smart mailboxes being expanded (for cycles).
    func sql(_ condition: SmartCondition, visited: Set<Int64> = []) -> (String, [(any DatabaseValueConvertible)?]) {
        guard condition.isEnabled else { return ("1", []) }
        switch condition {
        case .compound(let match, let children, _):
            let parts = children.filter(\.isEnabled).map { sql($0, visited: visited) }
            guard !parts.isEmpty else { return ("1", []) }
            let joined = "(" + parts.map(\.0).joined(separator: match == .all ? " AND " : " OR ") + ")"
            return (match == .none ? "NOT \(joined)" : joined, parts.flatMap(\.1))
        case .rule(.mailbox, let op, let value, _, _):
            guard let scope = MessageScope(key: value) else { return ("1", []) }
            let (clause, args) = sourceFilter(scope, visited: visited)
            return ("\(op.isNegative ? "NOT " : "")(\(clause))", args)
        case .rule(let field, let op, let value, _, let options):
            return rule(field, op, value, options)
        }
    }

    private static func like(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// A text test on `column`, positive form (negation is applied by the caller). Case-insensitive
    /// unless `options` say otherwise; "is in" takes a comma-separated list.
    private static func textTest(
        _ column: String, _ op: SmartOperator, _ value: String, _ options: SmartOptions = []
    ) -> (String, [(any DatabaseValueConvertible)?]) {
        let exact = options.contains(.caseSensitive)
        let col = exact ? column : "lower(\(column))"
        let v = exact ? value : value.lowercased()
        switch op {
        case .is, .isNot: return ("\(col) = ?", [v])
        case .contains, .doesNotContain: return ("instr(\(col), ?) > 0", [v])
        case .lessOrEqual: return ("\(col) <= ?", [v])
        case .moreOrEqual: return ("\(col) >= ?", [v])
        case .isIn, .isNotIn:
            let items = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !items.isEmpty else { return ("0", []) }
            return ("\(col) IN (\(Array(repeating: "?", count: items.count).joined(separator: ", ")))", items)
        case .exists, .notExists: return ("\(column) <> ''", [])
        case .beginsWith: return ("substr(\(col), 1, length(?)) = ?", [v, v])
        case .endsWith: return ("substr(\(col), -length(?)) = ?", [v, v])
        case .withinLast, .notWithinLast, .isExactly, .isBefore, .isAfter: return ("0", [])
        }
    }

    /// A date part's text (see `SmartField.DatePart`) as SQL, from when the message arrived, in the
    /// sender's time zone (from its Date header, when known, else this Mac's) or, `local`, this Mac's.
    static func dateText(_ part: SmartField.DatePart, local: Bool) -> String {
        let date = "m.receivedAt"
        let localOffset = "(CAST(strftime('%s', \(date), 'unixepoch', 'localtime') AS INTEGER) - CAST(\(date) AS INTEGER))"
        let offset = local ? localOffset : "coalesce(m.sentZone * 60, \(localOffset))"
        let shifted = "(\(date) + \(offset))"
        let zone = "printf('%s%02d%02d', CASE WHEN \(offset) < 0 THEN '-' ELSE '+' END, abs(\(offset)) / 3600, abs(\(offset)) % 3600 / 60)"
        func format(_ f: String) -> String { "strftime('\(f)', \(shifted), 'unixepoch')" }
        return switch part {
        case .day: format("%Y-%m-%d")
        case .month: format("%Y-%m")
        case .year: format("%Y")
        case .hour: format("%Y-%m-%d %H")
        case .time: format("%H:%M:%S")
        case .zone: zone
        case .formatted: "(\(format("%Y-%m-%d %H:%M:%S")) || ' ' || \(zone))"
        }
    }

    /// The period a date value names, in this Mac's time zone: a year ("2024"), month ("2024-03") or day
    /// ("2024-03-01"), also day first ("01-03-2024", "03-2024"), with "-", "/" or "." between.
    public static func datePeriod(_ value: String) -> (start: Date, end: Date)? {
        let numbers = value.split(whereSeparator: { "-/. ".contains($0) }).map(String.init)
        guard (1...3).contains(numbers.count), numbers.allSatisfy({ Int($0) != nil }) else { return nil }
        let ordered = numbers.first!.count == 4 ? numbers : numbers.last!.count == 4 ? numbers.reversed() : []
        guard let year = ordered.first.flatMap(Int.init), ordered.first?.count == 4 else { return nil }
        var parts = DateComponents(year: year, month: 1, day: 1)
        let unit: Calendar.Component
        switch ordered.count {
        case 1: unit = .year
        case 2: parts.month = Int(ordered[1]); unit = .month
        default: parts.month = Int(ordered[1]); parts.day = Int(ordered[2]); unit = .day
        }
        let calendar = Calendar.current
        guard (1...12).contains(parts.month ?? 1), (1...31).contains(parts.day ?? 1), let start = calendar.date(from: parts),
            calendar.component(.day, from: start) == parts.day ?? 1,  // not 31 February
            let end = calendar.date(byAdding: unit, value: 1, to: start)
        else { return nil }
        return (start, end)
    }

    private func rule(
        _ field: SmartField, _ op: SmartOperator, _ value: String, _ options: SmartOptions = []
    ) -> (String, [(any DatabaseValueConvertible)?]) {
        let not = op.isNegative ? "NOT " : ""
        switch field.kind {
        case .text:
            if let (header, part) = field.address {
                let roles = header.roles.map { String($0.rawValue) }.joined(separator: ", ")
                var (match, args) = Self.textTest(part.column, op, value, options)
                if part == .all, op.takesValue {  // No Specifier: the whole address, its name or its address
                    let (nameTest, nameArgs) = Self.textTest(SmartField.AddressPart.name.column, op, value, options)
                    let (displayTest, displayArgs) = Self.textTest(SmartField.AddressPart.display, op, value, options)
                    match = "(\(match) OR \(nameTest) OR \(displayTest))"
                    args += nameArgs + displayArgs
                }
                return ("\(not)EXISTS (SELECT 1 FROM address a WHERE a.messageId = m.id AND a.role IN (\(roles)) AND a.email <> '' AND \(match))", args)
            }
            switch field {
            case .body, .unquoted, .quoted, .headersOrUnquoted, .headersOrText:
                guard let query = Self.ftsQuery(value) else { return ("1", []) }
                // The index's columns each field searches (all of them for Common Headers or Text).
                let columns = [SmartField.body: "body", .unquoted: "unquoted", .quoted: "quoted",
                               .headersOrUnquoted: "{subject addresses unquoted}"][field]
                return ("m.id \(not)IN (SELECT rowid FROM message_fts WHERE message_fts MATCH ?)",
                        [columns.map { "\($0) : (\(query))" } ?? query])
            case .filename:
                let (test, args) = Self.textTest("coalesce(p.name, '')", op, value, options)
                return ("\(not)EXISTS (SELECT 1 FROM message_part p WHERE p.messageId = m.id AND p.name IS NOT NULL AND \(test))", args)
            case .keyword:
                let (test, args) = Self.textTest("k.keyword", op, value, options)
                return ("\(not)EXISTS (SELECT 1 FROM message_keyword k WHERE k.messageId = m.id AND \(test))", args)
            default:
                if let (part, local) = field.datePart {
                    let (test, args) = Self.textTest(Self.dateText(part, local: local), op, value, options)
                    return ("\(not)(\(test))", args)
                }
                let (test, args) = Self.textTest("m.subject", op, value, options)
                return ("\(not)(\(test))", args)
            }
        case .status:
            guard let status = SmartStatus(rawValue: value) else { return ("1", []) }
            return ("\(not)(\(status.sql))", [])
        case .days:
            // Date (and Received, from before) is the arrival; Sent, from before, the Date header.
            let column = field == .sent ? "coalesce(m.sentAt, m.receivedAt)" : "m.receivedAt"
            switch op {
            case .exists, .notExists:  // every message arrived; a sent date needs a Date header
                return field == .sent ? ("\(not)(m.sentAt IS NOT NULL)", []) : ("\(not)1", [])
            case .isExactly, .isBefore, .isAfter:
                guard let period = Self.datePeriod(value) else { return ("0", []) }
                let (start, end) = (period.start.timeIntervalSince1970, period.end.timeIntervalSince1970)
                return switch op {
                case .isBefore: ("\(column) < ?", [start])
                case .isAfter: ("\(column) >= ?", [end])
                default: ("(\(column) >= ? AND \(column) < ?)", [start, end])
                }
            default:
                let days = Double(value.trimmingCharacters(in: .whitespaces)) ?? 0
                return ("\(not)(\(column) >= ?)", [Date().timeIntervalSince1970 - days * 86_400])
            }
        case .mailbox:
            return ("1", [])  // handled by `sql`, which knows the context
        case .account:
            return ("\(not)(m.accountId = ?)", [value])
        }
    }
}

extension MessageScope {
    /// The scope itself, or for a special mailbox's submailbox (`within`) the submailbox's own.
    public var base: MessageScope {
        if case .within(_, let child) = self { return child.base }
        return self
    }

    /// The smart mailbox this scope lists (itself, or one of its submailboxes).
    public var smartID: Int64? {
        switch self {
        case .smart(let id), .smartValue(let id, _, _), .smartAccount(let id, _), .smartAccountValue(let id, _, _, _): id
        default: nil
        }
    }
}

// MARK: - Storage

extension MailStore {
    public func smartMailboxes() throws -> [SmartMailboxRecord] {
        try dbPool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, parentId, parentKey, name, sortOrder, definition FROM smart_mailbox ORDER BY sortOrder, id")
                .map { row in
                    let json: String = row["definition"]
                    let definition = (try? JSONDecoder().decode(SmartDefinition.self, from: Data(json.utf8))) ?? SmartDefinition()
                    return SmartMailboxRecord(
                        id: row["id"], parentId: row["parentId"], parentKey: row["parentKey"], name: row["name"], sortOrder: row["sortOrder"],
                        definition: definition)
                }
        }
    }

    /// Reloads the smart mailboxes lists resolve against.
    @discardableResult
    public func refreshSmartCatalog() throws -> [SmartMailboxRecord] {
        let list = try smartMailboxes()
        smartCatalog.set(list)
        let rows = try dbPool.read { db in try Row.fetchAll(db, sql: "SELECT key, condition FROM mailbox_condition") }
        var special: [String: SmartCondition] = [:]
        for row in rows {
            let json: String = row["condition"]
            if let condition = try? JSONDecoder().decode(SmartCondition.self, from: Data(json.utf8)) { special[row["key"]] = condition }
        }
        smartCatalog.setSpecial(special)
        smartCatalog.setPlaced(Dictionary(grouping: try specialPlacements(), by: \.parentId).mapValues { $0.map(\.key) })
        return list
    }

    // MARK: Special mailboxes

    /// The special mailboxes (MailMate's: Inbox, All Messages, Drafts, Sent, Deleted, Archive, Junk):
    /// their messages come from the accounts, but their Conditions tab can narrow them.
    public func specialCondition(key: String) -> SmartCondition { smartCatalog.special(key) ?? .compound(.all, []) }

    public func setSpecialCondition(_ condition: SmartCondition, key: String) throws {
        try dbPool.write { db in
            if Self.isEmpty(condition) {
                try db.execute(sql: "DELETE FROM mailbox_condition WHERE key = ?", arguments: [key])
            } else {
                let json = String(decoding: try JSONEncoder().encode(condition), as: UTF8.self)
                try db.execute(sql: "INSERT OR REPLACE INTO mailbox_condition (key, condition) VALUES (?, ?)", arguments: [key, json])
            }
        }
        try refreshSmartCatalog()
    }

    /// Whether a special mailbox's conditions narrow it (so its counts can't come from the server's).
    public func hasSpecialCondition(key: String) -> Bool { smartCatalog.special(key).map { !Self.isEmpty($0) } ?? false }

    /// A special mailbox's conditions as SQL, if it has any.
    /// A condition naming its own mailbox ("Inbox: Mailbox is Inbox") reads it without its conditions.
    func specialFilter(key: String) -> (String, [(any DatabaseValueConvertible)?])? {
        guard let condition = smartCatalog.special(key), !Self.isEmpty(condition) else { return nil }
        let thread = Thread.current.threadDictionary
        var expanding = thread["MMJSpecialExpanding"] as? Set<String> ?? []
        guard !expanding.contains(key) else { return nil }
        expanding.insert(key)
        thread["MMJSpecialExpanding"] = expanding
        defer {
            expanding.remove(key)
            thread["MMJSpecialExpanding"] = expanding
        }
        return sql(condition)
    }

    /// A new smart mailbox at the end of its parent's children: a child starts from its parent's
    /// messages, a top-level one with no mailboxes added (all messages), as MailMate's.
    /// Inside a special mailbox (`parentKey`, as MailMate's New Smart Mailbox on All Messages), it
    /// starts from that mailbox's messages.
    public func createSmartMailbox(name: String, parentId: Int64?, parentKey: String? = nil) throws -> Int64 {
        var definition = SmartDefinition(sources: SmartSources(scopes: []))
        if let parentId { definition.sources = SmartSources(scopes: [MessageScope.smart(parentId).key]) }
        if parentId == nil, let parentKey { definition.sources = SmartSources(scopes: [parentKey]) }
        let key = parentId == nil ? parentKey : nil
        let json = String(decoding: try JSONEncoder().encode(definition), as: UTF8.self)
        let id = try dbPool.write { db -> Int64 in
            let order = try Int.fetchOne(
                db, sql: "SELECT coalesce(max(sortOrder), -1) + 1 FROM smart_mailbox WHERE parentId IS ? AND parentKey IS ?",
                arguments: [parentId, key]) ?? 0
            try db.execute(
                sql: "INSERT INTO smart_mailbox (parentId, parentKey, name, definition, sortOrder) VALUES (?, ?, ?, ?, ?)",
                arguments: [parentId, key, name, json, order])
            return db.lastInsertedRowID
        }
        try refreshSmartCatalog()
        return id
    }

    /// A copy of smart mailbox `id` (its sources, conditions, submailbox settings and icon), named
    /// "<name> copy", right after it among its siblings. Smart mailboxes inside it aren't copied.
    public func duplicateSmartMailbox(id: Int64) throws -> Int64? {
        guard let original = try smartMailboxes().first(where: { $0.id == id }) else { return nil }
        let json = String(decoding: try JSONEncoder().encode(original.definition), as: UTF8.self)
        let copy = try dbPool.write { db -> Int64 in
            try db.execute(
                sql: "UPDATE smart_mailbox SET sortOrder = sortOrder + 1 WHERE parentId IS ? AND parentKey IS ? AND sortOrder > ?",
                arguments: [original.parentId, original.parentKey, original.sortOrder])
            try db.execute(
                sql: "INSERT INTO smart_mailbox (parentId, parentKey, name, definition, sortOrder) VALUES (?, ?, ?, ?, ?)",
                arguments: [original.parentId, original.parentKey, original.name + " copy", json, original.sortOrder + 1])
            return db.lastInsertedRowID
        }
        try refreshSmartCatalog()
        return copy
    }

    /// Moves a smart mailbox (dragged in the sidebar) to `index` among `parentId`'s smart mailboxes
    /// (the top level for nil). A smart mailbox can't go inside itself or one inside it.
    /// `parentKey` puts it inside a special mailbox instead (for a top-level one).
    public func moveSmartMailbox(id: Int64, toParent parentId: Int64?, parentKey: String? = nil, index: Int) throws {
        let all = try smartMailboxes()
        var ancestor = parentId
        while let current = ancestor {
            if current == id { return }
            ancestor = all.first { $0.id == current }?.parentId
        }
        let key = parentId == nil ? parentKey : nil
        var siblings = all.filter { $0.parentId == parentId && $0.parentKey == key && $0.id != id }.map(\.id)
        siblings.insert(id, at: min(max(0, index), siblings.count))
        try dbPool.write { db in
            try db.execute(sql: "UPDATE smart_mailbox SET parentId = ?, parentKey = ? WHERE id = ?", arguments: [parentId, key, id])
            for (order, sibling) in siblings.enumerated() {
                try db.execute(sql: "UPDATE smart_mailbox SET sortOrder = ? WHERE id = ?", arguments: [order, sibling])
            }
        }
        try refreshSmartCatalog()
    }

    /// Special mailboxes placed inside smart mailboxes: scope key, smart mailbox, in each one's order.
    public func specialPlacements() throws -> [(key: String, parentId: Int64)] {
        try dbPool.read { db in
            try Row.fetchAll(db, sql: "SELECT key, parentId FROM special_placement ORDER BY parentId, sortOrder")
                .map { ($0["key"], $0["parentId"]) }
        }
    }

    /// Places a special mailbox (by scope key) inside smart mailbox `parentId` at `index` among the special
    /// mailboxes there, or (nil) back among the top-level mailboxes.
    public func placeSpecialMailbox(key: String, inside parentId: Int64?, index: Int) throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM special_placement WHERE key = ?", arguments: [key])
            guard let parentId else { return }
            var keys = try String.fetchAll(
                db, sql: "SELECT key FROM special_placement WHERE parentId = ? ORDER BY sortOrder", arguments: [parentId])
            keys.insert(key, at: min(max(0, index), keys.count))
            try db.execute(sql: "DELETE FROM special_placement WHERE parentId = ?", arguments: [parentId])
            for (order, placed) in keys.enumerated() {
                try db.execute(
                    sql: "INSERT INTO special_placement (key, parentId, sortOrder) VALUES (?, ?, ?)",
                    arguments: [placed, parentId, order])
            }
        }
        try refreshSmartCatalog()
    }

    /// Puts a smart mailbox first among its siblings.
    public func moveSmartMailboxFirst(id: Int64) throws {
        try dbPool.write { db in
            let parent = try Int64?.fetchOne(db, sql: "SELECT parentId FROM smart_mailbox WHERE id = ?", arguments: [id]) ?? nil
            let lowest = try Int.fetchOne(
                db, sql: "SELECT coalesce(min(sortOrder), 0) FROM smart_mailbox WHERE parentId IS ?", arguments: [parent]) ?? 0
            try db.execute(sql: "UPDATE smart_mailbox SET sortOrder = ? WHERE id = ?", arguments: [lowest - 1, id])
        }
        try refreshSmartCatalog()
    }

    public func updateSmartMailbox(id: Int64, name: String? = nil, definition: SmartDefinition? = nil) throws {
        try dbPool.write { db in
            if let name { try db.execute(sql: "UPDATE smart_mailbox SET name = ? WHERE id = ?", arguments: [name, id]) }
            if let definition {
                let json = String(decoding: try JSONEncoder().encode(definition), as: UTF8.self)
                try db.execute(
                    sql: "UPDATE smart_mailbox SET definition = ?, version = version + 1 WHERE id = ?", arguments: [json, id])
            }
        }
        try refreshSmartCatalog()
    }

    /// Deletes a smart mailbox and the ones inside it.
    public func deleteSmartMailbox(id: Int64) throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM smart_mailbox WHERE id = ?", arguments: [id])  // children cascade
        }
        try refreshSmartCatalog()
    }

    /// The distinct values of `field` among a smart mailbox's messages (all messages for nil), A to Z
    /// ("Other" last), with how many of each are unread (for its submailboxes), at most `limit`.
    public func smartValues(
        id: Int64?, field: SmartField, account: String? = nil, limit: Int = 1000
    ) throws -> [(value: String, unread: Int)] {
        var (filter, args) = id.map { smartFilter(id: $0) } ?? ("1", [])
        if let account {  // within one account (values grouped under "each account")
            filter = "(\(filter)) AND m.accountId = ?"
            args.append(account)
        }
        guard let split = Self.splitSource(field) else { return [] }
        let keepsOther = field.address?.part.isName ?? false
        let tables = split.table.map { "message m, \($0)" } ?? "message m"
        let link = split.table == nil ? "1" : split.link
        let valueSQL = """
            SELECT \(split.column) AS v, count(DISTINCT m.id) AS n, count(DISTINCT CASE WHEN NOT m.isSeen THEN m.id END) AS u
            FROM \(tables)
            WHERE \(link) AND \(split.filter) AND \(filter) AND v IS NOT NULL\(keepsOther ? "" : " AND v <> ''")
            GROUP BY lower(v) ORDER BY v COLLATE NOCASE LIMIT ?
            """
        let values: [(value: String, unread: Int)] = try dbPool.read { db in
            try Row.fetchAll(db, sql: valueSQL, arguments: StatementArguments(args + [limit])).map { ($0["v"], $0["u"]) }
        }
        // "Other" (no name) comes last, as in MailMate.
        return values.filter { !$0.value.isEmpty } + values.filter { $0.value.isEmpty }
    }

    /// The values of a text field among the messages of `sources` (a smart mailbox's Mailboxes tab;
    /// all messages when empty), A to Z, for the "is" combo box: names, addresses or their parts,
    /// subjects, attachment names, keywords.
    public func fieldValues(_ field: SmartField, sources: SmartSources, limit: Int = 5000) throws -> [String] {
        let (filter, args) = Self.isEmpty(sources.root) ? filterParts(scope: .allMessages, search: nil) : sql(sources.root)
        let sql: String
        if let (header, part) = field.address {
            let roles = header.roles.map { String($0.rawValue) }.joined(separator: ", ")
            let column = part == .all ? SmartField.AddressPart.display : part.column
            sql = """
                SELECT DISTINCT \(column) AS v FROM message m JOIN address a ON a.messageId = m.id
                WHERE a.role IN (\(roles)) AND a.email <> '' AND \(filter) AND v <> '' ORDER BY v COLLATE NOCASE LIMIT ?
                """
        } else if field == .filename {
            sql = """
                SELECT DISTINCT p.name AS v FROM message m JOIN message_part p ON p.messageId = m.id
                WHERE p.name IS NOT NULL AND p.name <> '' AND \(filter) ORDER BY v COLLATE NOCASE LIMIT ?
                """
        } else if field == .keyword {
            sql = """
                SELECT DISTINCT k.keyword AS v FROM message m JOIN message_keyword k ON k.messageId = m.id
                WHERE \(filter) ORDER BY v COLLATE NOCASE LIMIT ?
                """
        } else if let (part, local) = field.datePart {
            sql = "SELECT DISTINCT \(Self.dateText(part, local: local)) AS v FROM message m WHERE \(filter) ORDER BY v DESC LIMIT ?"
        } else if field == .subject {
            sql = "SELECT DISTINCT m.subject AS v FROM message m WHERE m.subject <> '' AND \(filter) ORDER BY v COLLATE NOCASE LIMIT ?"
        } else {
            return []
        }
        return try dbPool.read { db in try String.fetchAll(db, sql: sql, arguments: StatementArguments(args + [limit])) }
    }

    /// Accounts with messages in a smart mailbox, with their unread counts (for "Submailbox for the
    /// messages of each account").
    public func smartAccounts(id: Int64) throws -> [(accountId: String, unread: Int)] {
        let (filter, args) = smartFilter(id: id)
        return try dbPool.read { db in
            try Row.fetchAll(
                db, sql: "SELECT m.accountId AS a, sum(NOT m.isSeen) AS u FROM message m WHERE \(filter) GROUP BY m.accountId",
                arguments: StatementArguments(args)
            ).map { ($0["a"], $0["u"]) }
        }
    }
}
