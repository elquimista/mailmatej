import Foundation
import GRDB

/// Smart mailboxes' unread counts and by-account submailboxes, kept from what each write changed
/// rather than counted anew: a refresh tests just the messages written since the last one against
/// every smart mailbox's conditions (milliseconds), where counting anew takes a query per smart
/// mailbox over all of its mail (hundreds of milliseconds, more as mail grows).
///
/// One per store (it takes the store's notes of what changed), refreshed by one caller at a time.
public final class SmartCounter: @unchecked Sendable {
    private let store: MailStore
    private let lock = NSLock()

    /// What each smart mailbox's messages are tested with: its conditions, as SQL for all mail and for a
    /// few messages; for one that includes its submailboxes' messages, its own (`smartOwnFilter`) when
    /// theirs can be added here (`includes`).
    private struct Test {
        var all: (sql: String, args: StatementArguments)
        var few: (sql: String, args: [(any DatabaseValueConvertible)?])
        var includes: [Int64]
    }

    private var tests: [Int64: Test] = [:]
    /// The messages (shown) each test picks, as of the last refresh.
    private var picked: [Int64: Set<Int64>] = [:]
    /// Each smart mailbox's messages: those its test picks, and its included submailboxes'.
    private var members: [Int64: Set<Int64>] = [:]
    /// Smart mailboxes whose messages change without any being written (see `MailStore.SQLNotes`):
    /// listed anew at each refresh.
    private var volatile: Set<Int64> = []
    private var unread: Set<Int64> = []
    /// Each shown message's account (an index into `accountIDs`).
    private var accountOf: [Int64: Int32] = [:]
    private var accountIDs: [String] = []
    private var accountIndex: [String: Int32] = [:]
    private var accountNames: [String: String] = [:]
    /// The catalog it was counted from, and when it was last counted anew.
    private var counted: (generation: Int, at: ContinuousClock.Instant)?
    /// Smart mailboxes some of whose messages changed in the last refresh (joined, left, or were marked).
    private var touched: Set<Int64> = []
    private var values: [ValuesKey: [(value: String, unread: Int)]] = [:]

    private struct ValuesKey: Hashable {
        let id: Int64
        let field: SmartField
        let account: String?
    }

    /// More changed messages than this are counted anew, which is quicker then.
    static let retestLimit = 5_000
    /// Counted anew this often anyway.
    static let recountInterval: Duration = .seconds(600)

    public init(store: MailStore) throws {
        self.store = store
        try store.noteChangedMessages()
    }

    /// Brings the counts up to date with the store.
    public func refresh() throws {
        try lock.withLock {
            do {
                let generation = store.smartCatalog.generation
                let changed = try store.takeChangedMessages()  // before reading: what follows is in the next
                if let counted, counted.generation == generation, !changed.mailboxesChanged,
                    changed.ids.count <= Self.retestLimit, counted.at.duration(to: .now) < Self.recountInterval
                {
                    try retest(Set(changed.ids))
                } else {
                    try recount(generation: generation)
                }
                let rows = try store.dbPool.read { db in try Row.fetchAll(db, sql: "SELECT id, name FROM account") }
                let names: [String: String] = Dictionary(rows.map { ($0["id"], $0["name"]) }, uniquingKeysWith: { a, _ in a })
                if names != accountNames { values = [:] }  // values by Mailbox name their accounts
                accountNames = names
                values = values.filter { !touched.contains($0.key.id) }
            } catch {
                counted = nil  // changes taken but not counted: anew next time
                throw error
            }
        }
    }

    // MARK: Results (as of the last refresh)

    /// A smart mailbox's unread messages, as `MailStore.count(scope: .smart(id), counting: .unread)`.
    public func unreadCount(smart id: Int64) -> Int? {
        lock.withLock {
            guard let set = members[id] else { return nil }
            return set.count < unread.count ? set.lazy.filter { self.unread.contains($0) }.count
                : unread.lazy.filter { set.contains($0) }.count
        }
    }

    /// The accounts with messages in a smart mailbox, and their unread counts, as `MailStore.smartAccounts`.
    public func accounts(smart id: Int64) -> [(accountId: String, unread: Int)]? {
        lock.withLock {
            guard let set = members[id] else { return nil }
            var counts: [Int32: Int] = [:]
            for message in set {
                guard let account = accountOf[message] else { continue }
                counts[account, default: 0] += unread.contains(message) ? 1 : 0
            }
            return counts.map { (accountIDs[Int($0.key)], $0.value) }
        }
    }

    /// The values of `field` among a smart mailbox's messages (in one account), as `MailStore.smartValues`:
    /// accounts' names from here, other fields queried again only once its messages change.
    public func values(smart id: Int64, field: SmartField, account: String? = nil) throws -> [(value: String, unread: Int)] {
        try lock.withLock {
            if field == .account, let set = members[id] {
                var byName: [String: (value: String, unread: Int)] = [:]
                for message in set {
                    guard let index = accountOf[message] else { continue }
                    let accountId = accountIDs[Int(index)]
                    guard account == nil || account == accountId, let name = accountNames[accountId], !name.isEmpty else { continue }
                    byName[name.lowercased(), default: (name, 0)].unread += unread.contains(message) ? 1 : 0
                }
                return byName.sorted { $0.key < $1.key }.map(\.value)
            }
            let key = ValuesKey(id: id, field: field, account: account)
            if let known = values[key] { return known }
            let fresh = try store.smartValues(id: id, field: field, account: account)
            values[key] = fresh
            return fresh
        }
    }

    // MARK: Counting

    private func recount(generation: Int) throws {
        var tests: [Int64: Test] = [:]
        var volatile = Set<Int64>()
        for record in store.smartCatalog.all {
            let id = record.id
            let notes = MailStore.SQLNotes()
            let whole = MailStore.$sqlNotes.withValue(notes) { store.smartFilter(id: id) }
            if notes.dependsOnNow || notes.dependsOnOtherMessages {
                volatile.insert(id)
                tests[id] = Test(all: (whole.0, StatementArguments(whole.1)), few: whole, includes: [])
            } else if let includes = store.includedSubmailboxes(of: id) {
                let own = store.smartOwnFilter(id: id)
                let few = MailStore.$testingFewMessages.withValue(true) { store.smartOwnFilter(id: id) }
                tests[id] = Test(all: (own.0, StatementArguments(own.1)), few: few, includes: includes)
            } else {
                let few = MailStore.$testingFewMessages.withValue(true) { store.smartFilter(id: id) }
                tests[id] = Test(all: (whole.0, StatementArguments(whole.1)), few: few, includes: [])
            }
        }
        var picked: [Int64: Set<Int64>] = [:]
        var accounts: [(Int64, String)] = []
        let unread: Set<Int64> = try store.dbPool.read { db in
            for (id, test) in tests {
                picked[id] = try Int64.fetchSet(
                    db, sql: "SELECT m.id FROM message m WHERE (\(test.all.sql)) AND \(MailStore.shown)", arguments: test.all.args)
            }
            let rows = try Row.fetchCursor(db, sql: "SELECT m.id, m.accountId FROM message m WHERE \(MailStore.shown)")
            while let row = try rows.next() { accounts.append((row[0], row[1])) }
            return try Int64.fetchSet(db, sql: "SELECT m.id FROM message m WHERE NOT m.isSeen AND \(MailStore.shown)")
        }
        self.tests = tests
        self.picked = picked
        self.volatile = volatile
        self.unread = unread
        accountOf = [:]
        accountOf.reserveCapacity(accounts.count)
        for (message, account) in accounts { accountOf[message] = intern(account) }
        values = [:]
        compose(touched: Set(tests.keys))
        counted = (generation, .now)
    }

    /// Tests the messages changed since the last refresh against each smart mailbox (and lists anew
    /// those that change without them).
    private func retest(_ changed: Set<Int64>) throws {
        let tested = tests.keys.filter { !volatile.contains($0) }
        var listed: [(id: Int64, sql: String, args: StatementArguments)] = []
        for id in volatile {
            let (sql, args) = store.smartFilter(id: id)  // as of now
            listed.append((id, sql, StatementArguments(args)))
        }
        guard !changed.isEmpty || !listed.isEmpty else { return compose(touched: []) }
        let list = "[" + changed.map(String.init).joined(separator: ",") + "]"
        var found: [Int64: (account: String, seen: Bool)] = [:]
        var matching: [Int64: Set<Int64>] = [:]
        var fresh: [Int64: Set<Int64>] = [:]
        try store.dbPool.read { db in
            if !changed.isEmpty {
                // Without any smart mailbox to test, still the messages' marks and accounts.
                let chunks = tested.isEmpty ? [ArraySlice<Int>()] : Array(tested.indices).chunked(40)
                for chunk in chunks {
                    let few = chunk.map { tests[tested[$0]]!.few }
                    let columns = few.map { ", coalesce(\($0.sql), 0)" }.joined()
                    let rows = try Row.fetchCursor(
                        db,
                        sql: """
                            SELECT m.id, m.accountId, m.isSeen\(columns) FROM message m
                            WHERE m.id IN (SELECT value FROM json_each(?)) AND \(MailStore.shown)
                            """,
                        arguments: StatementArguments(few.flatMap(\.args) + [list]))
                    while let row = try rows.next() {
                        let id: Int64 = row[0]
                        found[id] = (row[1], row[2])
                        for (column, index) in chunk.enumerated() where row[3 + column] as Bool {
                            matching[tested[index], default: []].insert(id)
                        }
                    }
                }
            }
            for filter in listed {
                fresh[filter.id] = try Int64.fetchSet(
                    db, sql: "SELECT m.id FROM message m WHERE (\(filter.sql)) AND \(MailStore.shown)", arguments: filter.args)
            }
        }
        var touched = volatile
        for id in tested {
            let matches = matching[id] ?? []
            guard var set = picked[id], !matches.isEmpty || !changed.isDisjoint(with: set) else { continue }
            set.subtract(changed)
            set.formUnion(matches)
            picked[id] = set
            touched.insert(id)
        }
        for (id, set) in fresh { picked[id] = set }
        unread.subtract(changed)
        for id in changed {
            if let (account, seen) = found[id] {
                accountOf[id] = intern(account)
                if !seen { unread.insert(id) }
            } else {
                accountOf[id] = nil  // gone, or not shown
            }
        }
        compose(touched: touched)
    }

    /// `members` from `picked`, and `touched` from the tests whose picks changed (one including its
    /// submailboxes' messages is touched with them).
    private func compose(touched changed: Set<Int64>) {
        var members: [Int64: Set<Int64>] = [:]
        var touched = Set<Int64>()
        func compose(_ id: Int64) {
            guard members[id] == nil else { return }
            var set = picked[id] ?? []
            for child in tests[id]?.includes ?? [] {
                compose(child)
                set.formUnion(members[child] ?? [])
                if touched.contains(child) { touched.insert(id) }
            }
            if changed.contains(id) { touched.insert(id) }
            members[id] = set
        }
        for id in tests.keys { compose(id) }
        self.members = members
        self.touched = touched
    }

    #if DEBUG
        /// Where the counts differ from counting anew (for checking).
        public func mismatches() throws -> [String] {
            var wrong: [String] = []
            for id in store.smartCatalog.all.map(\.id).sorted() {
                let unread = try store.count(scope: .smart(id), counting: .unread)
                if unreadCount(smart: id) != unread { wrong.append("smart \(id) unread \(unreadCount(smart: id) ?? -1), not \(unread)") }
                let fresh = Dictionary(try store.smartAccounts(id: id).map { ($0.accountId, $0.unread) }, uniquingKeysWith: +)
                let kept = Dictionary((accounts(smart: id) ?? []).map { ($0.accountId, $0.unread) }, uniquingKeysWith: +)
                if kept != fresh { wrong.append("smart \(id) accounts \(kept), not \(fresh)") }
                let names = try store.smartValues(id: id, field: .account).map { "\($0.value) \($0.unread)" }
                let keptNames = try values(smart: id, field: .account).map { "\($0.value) \($0.unread)" }
                if keptNames != names { wrong.append("smart \(id) by account \(keptNames), not \(names)") }
            }
            return wrong
        }
    #endif

    private func intern(_ account: String) -> Int32 {
        if let index = accountIndex[account] { return index }
        let index = Int32(accountIDs.count)
        accountIDs.append(account)
        accountIndex[account] = index
        return index
    }
}
