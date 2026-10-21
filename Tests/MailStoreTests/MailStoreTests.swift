import Foundation
import Testing

@testable import MailStore

@Suite struct MailStoreTests {
    let store: MailStore
    let account = AccountRecord(id: "acc", name: "Test", sessionURL: "http://x", username: "me@example.com", authKind: .basic)

    init() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mmj-test-\(UUID().uuidString)")
        store = try MailStore(directory: dir)
        try store.save(account)
        try store.applyMailboxes(accountId: "acc", upserts: [
            IncomingMailbox(remoteId: "in", parentRemoteId: nil, name: "Inbox", role: "inbox", sortOrder: 0, totalEmails: 0, unreadEmails: 1),
            IncomingMailbox(remoteId: "tr", parentRemoteId: nil, name: "Trash", role: "trash", sortOrder: 0, totalEmails: 0, unreadEmails: 0),
            IncomingMailbox(remoteId: "se", parentRemoteId: nil, name: "Sent", role: "sent", sortOrder: 0, totalEmails: 0, unreadEmails: 0),
        ], destroyed: [], replaceAll: true)
    }

    func message(_ id: String, from: String, to: String = "me@example.com", box: String = "in", at: Double,
                 subject: String = "Hello", keywords: [String] = []) -> IncomingMessage {
        IncomingMessage(
            remoteId: id, threadId: "t\(id)", blobId: "b\(id)", mailboxRemoteIds: [box], keywords: keywords, size: 100,
            receivedAt: Date(timeIntervalSince1970: at), sentAt: nil, messageIdHeader: nil, inReplyTo: nil,
            subject: subject, preview: "preview text \(id)", hasAttachment: false,
            addresses: [.init(role: .from, name: nil, email: from), .init(role: .to, name: nil, email: to)])
    }

    @Test func smartMailboxesMatchTheirConditions() throws {
        try store.upsertMessages(accountId: "acc", [
            message("1", from: "pay@payoneer.com", at: 100, subject: "You Have Received a Payment!"),
            message("2", from: "news@payoneer.com", at: 200, subject: "Newsletter"),
            message("3", from: "x@other.com", at: 300, subject: "Payment from Bob was deposited", keywords: ["$seen"]),
            message("4", from: "pay@payoneer.com", box: "tr", at: 400, subject: "You Have Received a Payment!"),
            message("5", from: "pay@payoneer.com", at: 500, subject: "Payment from Ann was deposited"),
        ])
        func subjects(_ scope: MessageScope) throws -> Set<String> {
            Set(try store.rows(ids: try store.messageIDs(scope: scope)).map { $0.subject })
        }
        // MailMate's Credit: Payoneer: From › Domain is payoneer.com, and Any of a subject or All of two words.
        let id = try store.createSmartMailbox(name: "Credit: Payoneer", parentId: nil)
        var definition = SmartDefinition()
        definition.condition = .compound(.all, [
            .rule(.fromDomain, .is, "Payoneer.com"),
            .compound(.any, [
                .rule(.subject, .is, "You have received a payment!"),
                .compound(.all, [.rule(.subject, .contains, "payment from"), .rule(.subject, .contains, "deposited")]),
            ]),
        ])
        try store.updateSmartMailbox(id: id, definition: definition)
        #expect(try subjects(.smart(id)) == ["Payment from Ann was deposited", "You Have Received a Payment!"])  // trash excluded

        // An unchecked row doesn't count.
        definition.condition = .compound(.all, [.rule(.fromDomain, .is, "payoneer.com"), .rule(.subject, .is, "Newsletter", enabled: false)])
        try store.updateSmartMailbox(id: id, definition: definition)
        #expect(try store.messageIDs(scope: .smart(id)).count == 3)

        // None of the rows: payoneer.com mail that is neither newsletter nor deposit.
        definition.condition = .compound(.all, [
            .rule(.fromDomain, .is, "payoneer.com"),
            .compound(.none, [.rule(.subject, .is, "Newsletter"), .rule(.subject, .contains, "deposited")]),
        ])
        try store.updateSmartMailbox(id: id, definition: definition)
        #expect(try subjects(.smart(id)) == ["You Have Received a Payment!"])
        definition.condition = .compound(.all, [.rule(.fromDomain, .is, "payoneer.com")])
        try store.updateSmartMailbox(id: id, definition: definition)

        // Negation, status and a child that starts from its parent's messages.
        let child = try store.createSmartMailbox(name: "Unread elsewhere", parentId: nil)
        try store.updateSmartMailbox(id: child, definition: SmartDefinition(
            sources: SmartSources(scopes: ["role:inbox"]),
            condition: .compound(.all, [.rule(.fromDomain, .isNot, "payoneer.com")])))
        #expect(try subjects(.smart(child)) == ["Payment from Bob was deposited"])
        let nested = try store.createSmartMailbox(name: "Nested", parentId: id)
        #expect(try store.smartMailboxes().first { $0.id == nested }?.definition.sources.scopes == ["smart:\(id)"])
        // Sources nest too: Inbox, or All of (All Messages and not Inbox) - the latter matching Sent only.
        let sourced = try store.createSmartMailbox(name: "Sourced", parentId: nil)
        try store.updateSmartMailbox(id: sourced, definition: SmartDefinition(sources: SmartSources(root: .compound(.any, [
            .rule(.mailbox, .is, "role:sent"),
            .compound(.all, [.rule(.mailbox, .is, "all"), .rule(.mailbox, .isNot, "role:inbox")]),
        ]))))
        #expect(try store.messageIDs(scope: .smart(sourced)).isEmpty)
        try store.deleteSmartMailbox(id: sourced)
        try store.updateSmartMailbox(id: nested, definition: SmartDefinition(
            sources: SmartSources(scopes: ["smart:\(id)"]), condition: .compound(.all, [.rule(.status, .is, "unread")])))
        #expect(try store.messageIDs(scope: .smart(nested)).count == 3)

        // Submailboxes by From › Address.
        let values = try store.smartValues(id: id, field: .fromAddress)
        #expect(values.map(\.value) == ["news@payoneer.com", "pay@payoneer.com"])  // A to Z
        #expect(values.map(\.unread) == [1, 2])
        #expect(try store.messageIDs(scope: .smartValue(id, .fromAddress, "news@payoneer.com")).count == 1)
        #expect(MessageScope(key: MessageScope.smartValue(id, .fromName, "A: B").key) == .smartValue(id, .fromName, "A: B"))

        // "Include messages in any submailboxes": an empty-handed parent shows its children's messages.
        let parent = try store.createSmartMailbox(name: "Parent", parentId: nil)
        try store.updateSmartMailbox(id: parent, definition: SmartDefinition(
            condition: .compound(.all, [.rule(.subject, .is, "nothing matches this")])))
        let kid = try store.createSmartMailbox(name: "Kid", parentId: parent)
        try store.updateSmartMailbox(id: kid, definition: SmartDefinition(condition: .compound(.all, [.rule(.subject, .is, "Newsletter")])))
        #expect(try store.messageIDs(scope: .smart(parent)).isEmpty)
        var including = try #require(try store.smartMailboxes().first { $0.id == parent }).definition
        including.sources.includeSubmailboxes = true
        try store.updateSmartMailbox(id: parent, definition: including)
        #expect(try subjects(.smart(parent)) == ["Newsletter"])
        try store.deleteSmartMailbox(id: parent)

        // Mailboxes that use each other as sources match nothing rather than loop.
        try store.updateSmartMailbox(id: id, definition: SmartDefinition(sources: SmartSources(scopes: ["smart:\(nested)"])))
        #expect(try store.messageIDs(scope: .smart(id)).isEmpty)
        try store.deleteSmartMailbox(id: id)
        #expect(try store.smartMailboxes().map(\.id) == [child])  // the nested one went with it
    }

    @Test func smartFieldsCoverMailMatesMenu() throws {
        var a = message("a", from: "Ann <ann@mail.payoneer.co.uk>", at: 100, subject: "One", keywords: ["$label1"])
        a.addresses = [.init(role: .from, name: "Ann Lee", email: "ann@mail.payoneer.co.uk"), .init(role: .bcc, name: nil, email: "me@example.com")]
        let b = message("b", from: "bob@x.com", at: Date().timeIntervalSince1970 - 3600, subject: "Two")
        try store.upsertMessages(accountId: "acc", [a, b])
        let id = try store.createSmartMailbox(name: "S", parentId: nil)
        func matches(_ condition: SmartCondition) throws -> Set<String> {
            try store.updateSmartMailbox(id: id, definition: SmartDefinition(condition: .compound(.all, [condition])))
            return Set(try store.rows(ids: try store.messageIDs(scope: .smart(id))).map(\.subject))
        }
        #expect(try matches(.rule(.address(.from, .user), .is, "ann")) == ["One"])
        #expect(try matches(.rule(.address(.from, .top), .is, "uk")) == ["One"])
        #expect(try matches(.rule(.address(.from, .second), .is, "co.uk")) == ["One"])
        #expect(try matches(.rule(.address(.from, .third), .is, "payoneer.co.uk")) == ["One"])
        #expect(try matches(.rule(.address(.from, .all), .contains, "ann lee")) == ["One"])  // No Specifier: name or address
        #expect(try matches(.rule(.address(.from, .all), .is, "Ann Lee <ann@mail.payoneer.co.uk>")) == ["One"])  // or both
        #expect(try store.fieldValues(.address(.from, .all), sources: SmartSources(scopes: [])) == ["Ann Lee <ann@mail.payoneer.co.uk>", "bob@x.com"])
        #expect(try matches(.rule(.address(.recipient, .address), .is, "me@example.com")) == ["One", "Two"])  // Bcc, To
        #expect(try matches(.rule(.address(.bcc, .address), .is, "me@example.com")) == ["One"])
        #expect(try matches(.rule(.keyword, .is, "$label1")) == ["One"])
        #expect(try matches(.rule(.sent, .withinLast, "1")) == ["Two"])
        #expect(try matches(.rule(.status, .isNot, "unread")) == [])
        // Submailboxes by any text field: keyword, From ‣ Second-Level, From (whole address).
        try store.updateSmartMailbox(id: id, definition: SmartDefinition())
        #expect(try store.smartValues(id: id, field: .keyword).map(\.value) == ["$label1"])
        #expect(Set(try store.smartValues(id: id, field: .address(.from, .second)).map(\.value)) == ["co.uk", "x.com"])
        #expect(try store.messageIDs(scope: .smartValue(id, .address(.from, .all), "Ann Lee <ann@mail.payoneer.co.uk>")).count == 1)
        #expect(!MailStore.canSplit(by: .received) && MailStore.canSplit(by: .filename))
        #expect(try store.smartValues(id: id, field: .mailbox).map(\.value) == ["Inbox \u{2013} Test"])
        #expect(try store.messageIDs(scope: .smartValue(id, .mailbox, "Inbox \u{2013} Test")).count == 2)
        #expect(try store.smartValues(id: id, field: .account).map(\.value) == ["Test"])
        // By name, senders without one go into "Other" (""), last.
        #expect(try store.smartValues(id: id, field: .fromName).map(\.value) == ["Ann Lee", ""])
        #expect(try store.rows(ids: try store.messageIDs(scope: .smartValue(id, .fromName, ""))).map(\.subject) == ["Two"])
        // Values within an account (both "each account" and a value split).
        #expect(try store.smartValues(id: id, field: .keyword, account: "acc").map(\.value) == ["$label1"])
        #expect(try store.smartValues(id: id, field: .keyword, account: "other").isEmpty)
        let grouped = MessageScope.smartAccountValue(id, "acc", .keyword, "$label1")
        #expect(MessageScope(key: grouped.key) == grouped)
        #expect(try store.messageIDs(scope: grouped).count == 1)
        // MailMate's operators and Options.
        #expect(try matches(.rule(.subject, .isIn, "two, three")) == ["Two"])
        #expect(try matches(.rule(.subject, .isNotIn, "two")) == ["One"])
        #expect(try matches(.rule(.subject, .lessOrEqual, "one")) == ["One"])
        #expect(try matches(.rule(.subject, .moreOrEqual, "p")) == ["Two"])
        #expect(try matches(.rule(.address(.bcc, .address), .exists, "")) == ["One"])
        #expect(try matches(.rule(.address(.bcc, .address), .notExists, "")) == ["Two"])
        #expect(try matches(.rule(.subject, .contains, "ONE")) == ["One"])
        #expect(try matches(.rule(.subject, .contains, "ONE", options: .caseSensitive)) == [])
        #expect(try matches(.rule(.subject, .is, "One", options: .caseSensitive)) == ["One"])
    }

    @Test func rulesMatchNewMessagesInTheirMailbox() throws {
        try store.upsertMessages(accountId: "acc", [
            message("1", from: "alert@alert.go2bank.com", at: 100, subject: "Your GO2bank statement"),
            message("2", from: "alert@alert.go2bank.com", box: "se", at: 200, subject: "Your GO2bank statement"),
            message("3", from: "x@other.com", at: 300, subject: "Your GO2bank statement"),
        ])
        let ids = try store.messageIDs(accountId: "acc", remoteIds: ["1", "2", "3"])
        #expect(ids.count == 3)
        let rule = RuleDefinition(name: "GO2bank alerts", condition: .compound(.all, [
            .rule(.fromDomain, .is, "alert.go2bank.com"), .rule(.subject, .contains, "go2bank stat"),
        ]), actions: [RuleAction(kind: .setKeyword, value: "$seen"), RuleAction(kind: .delete)])
        let id = try store.createRule(mailboxKey: "role:inbox", definition: rule)
        let record = try #require(try store.rules(mailboxKey: "role:inbox").first)
        #expect(record.id == id && record.definition == rule)
        // Only the inbox message from that domain: not the one in Sent, not another sender.
        #expect(try store.rows(ids: try store.messages(ids, matching: record)).map(\.subject) == ["Your GO2bank statement"])
        #expect(try store.messages(ids, matching: record).count == 1)
        // Subrules: duplicated with their rule, deleted with it.
        let sub = try store.createRule(mailboxKey: "role:inbox", parentId: id, definition: RuleDefinition(name: "Sub"))
        #expect(try store.rules().first { $0.id == sub }?.parentId == id)
        let copy = try #require(try store.duplicateRule(id: id))
        let all = try store.rules(mailboxKey: "role:inbox")
        #expect(all.first { $0.id == copy }?.definition.name == "GO2bank alerts copy")
        #expect(all.contains { $0.parentId == copy && $0.definition.name == "Sub" })
        #expect(all.filter { $0.parentId == nil }.map(\.id) == [id, copy])  // the copy right after it
        try store.deleteRule(id: id)
        try store.deleteRule(id: copy)
        #expect(try store.rules().isEmpty)
    }

    @Test func scopesAndOrdering() throws {
        try store.upsertMessages(accountId: "acc", [
            message("1", from: "a@x.com", at: 100),
            message("2", from: "b@x.com", box: "tr", at: 200),
            message("3", from: "c@x.com", at: 300, keywords: ["$flagged", "$seen"]),
        ])
        let inbox = try store.messageIDs(scope: .role("inbox"))
        #expect(inbox.count == 2)
        #expect(try store.rows(ids: [inbox[0]]).first?.fromEmail == "c@x.com")  // newest first
        #expect(try store.messageIDs(scope: .allMessages).count == 2)  // trash excluded
        #expect(try store.messageIDs(scope: .flagged).count == 1)
        let bySubject = try store.messageIDs(scope: .role("inbox"), sort: MessageSort(key: .from, ascending: true))
        #expect(try store.newestMessageID(scope: .role("inbox")) == bySubject.last)  // c@x.com, newest
        #expect(try store.rows(ids: inbox).first { $0.fromEmail == "c@x.com" }?.isSeen == true)
    }

    @Test func upsertUpdatesInPlaceAndDeleteCascades() throws {
        try store.upsertMessages(accountId: "acc", [message("1", from: "a@x.com", at: 100)])
        let id = try #require(store.messageIDs(scope: .allMessages).first)
        try store.upsertMessages(accountId: "acc", [message("1", from: "a@x.com", box: "tr", at: 100, keywords: ["$seen"])])
        #expect(try store.messageIDs(scope: .allMessages).isEmpty)
        #expect(try store.messageIDs(scope: .role("trash")) == [id])  // same local id

        try store.deleteMessages(accountId: "acc", remoteIds: ["1"])
        #expect(try store.messageIDs(scope: .account("acc")).isEmpty)
        #expect(try store.correspondenceIDs(email: "a@x.com").isEmpty)
        #expect(try store.messageIDs(scope: .account("acc"), search: "preview").isEmpty)
    }

    @Test func correspondence() throws {
        try store.upsertMessages(accountId: "acc", [
            message("1", from: "Ada@X.com", at: 100),
            message("2", from: "me@example.com", to: "ada@x.com", box: "se", at: 200),
            message("3", from: "bob@x.com", at: 300),
        ])
        let me = try store.myAddresses()
        #expect(me.contains("me@example.com"))
        let sent = try #require(try store.messageIDs(scope: .role("sent")).first)
        #expect(try store.correspondent(messageId: sent, myAddresses: me) == "ada@x.com")
        let thread = try store.correspondenceIDs(email: "ada@x.com")
        #expect(thread.count == 2)
        #expect(thread.first == sent)
        let oldestFirst = try store.correspondenceIDs(email: "ada@x.com", sort: MessageSort(key: .receivedAt, ascending: true))
        #expect(oldestFirst == thread.reversed())

        // Deleted messages are left out, unless the pane is for that message.
        try store.upsertMessages(accountId: "acc", [message("4", from: "ada@x.com", box: "tr", at: 400)])
        let deleted = try #require(try store.messageIDs(scope: .role("trash")).first)
        #expect(try store.correspondenceIDs(email: "ada@x.com") == thread)
        #expect(try store.correspondenceIDs(email: "ada@x.com", keeping: deleted) == [deleted] + thread)
    }

    @Test func addressFieldParsing() {
        #expect(AccountRecord.addresses(in: "a@x.com, <B@Y.org>; Name <c@z.co.uk>, a@x.com d@w.io junk") == ["a@x.com", "b@y.org", "c@z.co.uk", "d@w.io"])
        let named = AccountRecord.namedAddresses(in: #""Sales, EU" <s@x.com>, eScreenly Support <support@x.com>, <p@x.com>"#)
        #expect(named.map(\.email) == ["s@x.com", "support@x.com", "p@x.com"])
        #expect(named.map(\.name) == ["Sales, EU", "eScreenly Support", nil])
        #expect(AccountRecord.addresses(in: "").isEmpty)
    }

    @Test func identitiesFollowTheAddressField() throws {
        try store.replaceIdentities(accountId: "acc", [("1", "", "abuse@x.com"), ("2", "", "me@example.com"), ("3", "", "pm@x.com")])
        #expect(try store.identities().map(\.email) == ["abuse@x.com", "me@example.com", "pm@x.com"])  // none listed: all
        var listed = account
        listed.emailAddresses = "pm@x.com, <me@example.com>, eScreenly Support <support@other.com>"
        listed.fullName = "Postmaster"
        try store.save(listed)
        let ids = try store.identities()
        #expect(ids.map(\.email) == ["pm@x.com", "me@example.com", "support@other.com"])  // listed, in order
        #expect(ids[0].name == "Postmaster" && ids[0].remoteId == "3" && ids[0].envelopeEmail == nil)
        // No server identity: sent through the login's own one (its username), with the field's name.
        #expect(ids[2].name == "eScreenly Support" && ids[2].remoteId == "2" && ids[2].envelopeEmail == "me@example.com")
        #expect(try store.myAddresses().contains("support@other.com"))
    }

    @Test func archiveFolderWithoutRoleIsUsed() throws {
        func box(_ id: String, _ name: String, role: String? = nil, parent: String? = nil) -> IncomingMailbox {
            IncomingMailbox(remoteId: id, parentRemoteId: parent, name: name, role: role, sortOrder: 0, totalEmails: 0, unreadEmails: 0)
        }
        try store.applyMailboxes(
            accountId: "acc", upserts: [box("in", "Inbox", role: "inbox"), box("x", "Archive", parent: "in"), box("a", "Archive")],
            destroyed: [], replaceAll: true)
        #expect(try store.mailbox(accountId: "acc", role: "archive")?.remoteId == "a")  // top level, by name
        try store.applyMailboxes(accountId: "acc", upserts: [box("a", "Archive")], destroyed: [], replaceAll: false)
        #expect(try store.mailbox(accountId: "acc", role: "archive")?.remoteId == "a")  // kept after a sync
        try store.applyMailboxes(accountId: "acc", upserts: [box("z", "Old Mail", role: "archive")], destroyed: [], replaceAll: false)
        #expect(try store.mailboxes().filter { $0.role == "archive" }.map(\.remoteId) == ["z"])  // the server's wins
    }

    @Test func threadsGroupConversations() {
        typealias T = MailStore.ThreadInput
        // Sorted newest first: c2 (replies to c1), b2 (replies to a), c1, a, d (alone).
        let rows = [
            T(id: 5, at: 50, seen: true, messageId: "c2", inReplyTo: "c1"), T(id: 4, at: 40, seen: false, messageId: "b2", inReplyTo: "a"),
            T(id: 3, at: 30, seen: true, messageId: "c1"), T(id: 2, at: 20, seen: true, messageId: "a"),
            T(id: 1, at: 10, seen: true, messageId: "d"),
        ]
        let keys = MailStore.threadKeys(rows)
        let (t1, t2, t3) = (keys[2]!, keys[3]!, keys[1]!)
        #expect(keys[4] == t1 && keys[5] == t2 && Set([t1, t2, t3]).count == 3)
        let open = MailStore.thread(rows, expanded: [t1, t2, t3])
        #expect(open.map(\.id) == [3, 5, 2, 4, 1])  // each thread where it first sorts, oldest message first
        #expect(open.map(\.depth) == [0, 1, 0, 1, 0])
        #expect(open.map(\.size) == [2, 1, 2, 1, 1])
        #expect(open.first { $0.id == 2 }?.anyUnread == true)  // its reply is unread
        #expect(MailStore.thread(rows, expanded: [t2]).map(\.id) == [3, 5, 2, 1])
        #expect(MailStore.thread(rows, expanded: []).map(\.id) == [3, 2, 1])  // threads start collapsed
    }

    @Test func threadsSortedByDateGoWhereTheirNewestMessageIs() {
        typealias T = MailStore.ThreadInput
        // Oldest first: a (answered today by a3), b, c, a3. The new reply brings thread a to the bottom,
        // next to the new mail, not up where a was.
        let rows = [
            T(id: 1, at: 10, seen: true, messageId: "a"), T(id: 2, at: 20, seen: true, messageId: "b"),
            T(id: 3, at: 30, seen: true, messageId: "c"), T(id: 4, at: 40, seen: false, messageId: "a3", inReplyTo: "a"),
        ]
        #expect(MailStore.thread(rows, expanded: [], placeAtNewest: true).map(\.id) == [2, 3, 1])
        #expect(MailStore.thread(rows, expanded: []).map(\.id) == [1, 2, 3])
        // A closed thread shows its newest message's date.
        #expect(MailStore.thread(rows, expanded: []).first { $0.id == 1 }?.newestAt == 40)
        // Newest first it already sorts there.
        #expect(MailStore.thread(rows.reversed(), expanded: [], placeAtNewest: true).map(\.id) == [1, 3, 2])
    }

    @Test func threadsNestReplies() {
        typealias T = MailStore.ThreadInput
        // a ← b ← d, a ← c (by References only), and e replying to a message not in the list.
        let rows = [
            T(id: 1, at: 10, seen: true, messageId: "a"),
            T(id: 2, at: 20, seen: true, messageId: "b", inReplyTo: "a"),
            T(id: 3, at: 30, seen: true, messageId: "c", references: ["a"]),
            T(id: 4, at: 40, seen: true, messageId: "d", inReplyTo: "b"),
            T(id: 5, at: 50, seen: true, messageId: "e", inReplyTo: "missing"),
        ]
        let t = MailStore.threadKeys(rows)[1]!
        let tree = MailStore.thread(rows.reversed(), expanded: [t], opened: [2])
        #expect(tree.map(\.id) == [5, 1, 2, 4, 3])  // e, whose parent isn't listed, is a thread of its own
        #expect(tree.map(\.depth) == [0, 0, 1, 2, 1])
        #expect(tree.map(\.hasReplies) == [false, true, true, false, false])  // chevrons on 1 and 2
        // Branches start folded too: without opening 2, its reply (4) is hidden, not its siblings.
        #expect(MailStore.thread(rows, expanded: [t]).map(\.id) == [1, 2, 3, 5])
        // A loop of In-Reply-To headers still lists every message once, as one thread.
        let loop = [
            T(id: 1, at: 10, seen: true, messageId: "x", inReplyTo: "y"),
            T(id: 2, at: 20, seen: true, messageId: "y", inReplyTo: "x"),
        ]
        let l = MailStore.threadKeys(loop)
        #expect(l[1] == l[2])
        #expect(Set(MailStore.thread(loop, expanded: [l[1]!]).map(\.id)) == [1, 2])
    }

    @Test func fuzzyMatchFindsLettersInOrder() {
        let postmasterInbox = ["postmaster@mail.example Inbox", "Inbox postmaster@mail.example"]
        #expect(FuzzyMatch.score("postin", in: postmasterInbox) != nil)  // MailMate's example
        #expect(FuzzyMatch.score("post in", in: postmasterInbox) != nil)
        #expect(FuzzyMatch.score("inpost", in: postmasterInbox) != nil)  // either order of account and name
        #expect(FuzzyMatch.score("postzin", in: postmasterInbox) == nil)  // no z anywhere
        // Tighter matches rank first: postmaster's Inbox before an Inbox whose account just has the letters.
        let loose = ["peter.ostwald@xample.com Inbox", "Inbox peter.ostwald@xample.com"]
        #expect(FuzzyMatch.score("postin", in: postmasterInbox)! < FuzzyMatch.score("postin", in: loose)!)
        #expect(FuzzyMatch.score("arch", in: ["Unified Archive"])! < FuzzyMatch.score("arch", in: ["Unified Search Results"])!)
        #expect(FuzzyMatch.score("", in: ["x"]) == 0)
    }

    @Test func ancestorsLeadFromTheFirstMessage() {
        typealias T = MailStore.ThreadInput
        let rows = [
            T(id: 1, at: 10, seen: true, messageId: "a"),
            T(id: 2, at: 20, seen: true, messageId: "b", inReplyTo: "a"),
            T(id: 3, at: 30, seen: true, messageId: "c", inReplyTo: "b"),
            T(id: 4, at: 40, seen: true, messageId: "x", inReplyTo: "y"),
            T(id: 5, at: 50, seen: true, messageId: "y", inReplyTo: "x"),
        ]
        #expect(MailStore.ancestors(of: 3, in: rows) == [1, 2])
        #expect(MailStore.ancestors(of: 1, in: rows).isEmpty)
        #expect(MailStore.ancestors(of: 4, in: rows) == [5])  // a loop stops where it comes back
    }

    @Test func threadsFollowOnlyTheDirectParentInTheList() {
        typealias T = MailStore.ThreadInput
        // The Inbox of the MailMate example: Phil's message (a), your reply in Sent (b, not listed), and
        // Phil's answer (c) whose References name both. MailMate keeps a and c apart in the Inbox.
        let inbox = [
            T(id: 1, account: "x", at: 10, seen: true, messageId: "a"),
            T(id: 3, account: "x", at: 30, seen: true, messageId: "c", inReplyTo: "b", references: ["a", "b"]),
        ]
        let keys = MailStore.threadKeys(inbox)
        #expect(keys[1] != keys[3])
        // With the reply listed (as in the Correspondence pane), all three are one thread.
        let all = inbox + [T(id: 2, account: "x", at: 20, seen: true, messageId: "b", inReplyTo: "a", references: ["a"])]
        let allKeys = MailStore.threadKeys(all)
        #expect(Set(allKeys.values).count == 1)
        #expect(MailStore.thread(all, expanded: [allKeys[1]!], opened: [2]).map(\.depth) == [0, 1, 2])
        // The same Message-ID in another account doesn't link across accounts.
        let other = [T(id: 1, account: "x", at: 10, seen: true, messageId: "a"), T(id: 2, account: "y", at: 20, seen: true, inReplyTo: "a")]
        let otherKeys = MailStore.threadKeys(other)
        #expect(otherKeys[1] != otherKeys[2])
    }

    @Test func submailboxScopes() throws {
        try store.upsertMessages(accountId: "acc", [
            message("1", from: "a@x.com", at: 100, keywords: ["$flagged"]),
            message("2", from: "b@x.com", box: "tr", at: 200, keywords: ["$flagged"]),
            message("3", from: "c@x.com", at: 300),
        ])
        let inbox = try #require(try store.mailboxes().first { $0.role == "inbox" })
        #expect(try store.messageIDs(scope: .flaggedInMailbox(inbox.id)).count == 1)
        #expect(try store.messageIDs(scope: .flaggedInAccount("acc")).count == 2)
        #expect(try store.messageIDs(scope: .allInAccount("acc")).count == 2)  // not the one in Trash
        let counts = try store.counts(flaggedByMailbox: true)
        #expect(counts.flaggedByMailbox[inbox.id] == 1)
        #expect(counts.flaggedByAccount["acc"] == 2)
    }

    @Test func correspondenceStaysWithTheAddressUsed() throws {
        try store.upsertMessages(accountId: "acc", [
            message("1", from: "ada@x.com", to: "me@example.com", at: 100),
            message("2", from: "ada@x.com", to: "alias@example.com", at: 200),
            message("3", from: "me@example.com", to: "ada@x.com", box: "se", at: 300),
        ])
        let me: Set = ["me@example.com", "alias@example.com"]
        let ids = try store.messageIDs(scope: .allMessages, sort: MessageSort(key: .receivedAt, ascending: true))
        #expect(try store.myAddress(in: ids[0], myAddresses: me) == "me@example.com")
        #expect(try store.myAddress(in: ids[1], myAddresses: me) == "alias@example.com")
        #expect(try store.myAddress(in: ids[2], myAddresses: me) == "me@example.com")
        #expect(Set(try store.correspondenceIDs(email: "ada@x.com", via: "me@example.com")) == [ids[0], ids[2]])
        #expect(try store.correspondenceIDs(email: "ada@x.com", via: "alias@example.com") == [ids[1]])
        #expect(try store.correspondenceIDs(email: "ada@x.com").count == 3)  // none of mine: everything
    }

    @Test func partsAndRemoteAllowList() throws {
        try store.upsertMessages(accountId: "acc", [message("1", from: "a@x.com", at: 100)])
        let id = try #require(store.messageIDs(scope: .allMessages).first)
        try store.saveBody(messageId: id, MessageBody(html: "<img src=cid:Logo@X>", text: nil), parts: [
            MessagePart(blobId: "B1", cid: "<Logo@X>", type: "image/png", name: "logo.png", size: 10)
        ])
        #expect(try store.part(messageId: id, cid: "logo@x")?.part.blobId == "B1")
        #expect(try store.part(messageId: id, cid: "<LOGO@x>")?.accountId == "acc")

        #expect(try !store.isRemoteContentAllowed(email: "news@shop.com"))
        try store.allowRemoteContent("@Shop.com")
        #expect(try store.isRemoteContentAllowed(email: "News@shop.com"))
        #expect(try !store.isRemoteContentAllowed(email: "news@other.com"))
        try store.disallowRemoteContent("@shop.com")
        #expect(try !store.isRemoteContentAllowed(email: "news@shop.com"))
    }

    @Test func downloadQueueIsNewestFirstAndResetsOnBlobChange() throws {
        try store.upsertMessages(accountId: "acc", [
            message("1", from: "a@x.com", at: 100), message("2", from: "b@x.com", at: 300), message("3", from: "c@x.com", at: 200),
        ])
        let pending = try store.pendingDownloads(accountId: "acc", limit: 10)
        #expect(pending.map(\.remoteId) == ["2", "3", "1"])
        #expect(pending.allSatisfy { !$0.hasBody })

        try store.setDownloadState(1, messageIds: pending.map(\.id))
        #expect(try store.pendingDownloads(accountId: "acc", limit: 10).isEmpty)
        #expect(try store.downloadProgress(accountId: "acc") == (3, 3))

        // Same blob: stays downloaded. New blob (message content replaced): queued again.
        try store.upsertMessages(accountId: "acc", [message("2", from: "b@x.com", at: 300, keywords: ["$seen"])])
        #expect(try store.pendingDownloads(accountId: "acc", limit: 10).isEmpty)
        var changed = message("1", from: "a@x.com", at: 100)
        changed.blobId = "new-blob"
        try store.upsertMessages(accountId: "acc", [changed])
        #expect(try store.pendingDownloads(accountId: "acc", limit: 10).map(\.remoteId) == ["1"])

        try store.setDownloadState(2, messageIds: [pending[2].id])
        #expect(try store.pendingDownloads(accountId: "acc", limit: 10).isEmpty)
        try store.retryFailedDownloads()
        #expect(try store.pendingDownloads(accountId: "acc", limit: 10).count == 1)
    }

    @Test func downloadBookkeepingDoesNotNotifyTheUI() throws {
        try store.upsertMessages(accountId: "acc", [message("1", from: "a@x.com", at: 100)])
        let id = try #require(store.messageIDs(scope: .allMessages).first)
        let count = Counter()
        let observation = store.observeChanges { count.increment() }
        defer { observation.cancel() }

        try store.setDownloadState(1, messageIds: [id])
        try store.saveBody(messageId: id, MessageBody(html: nil, text: "full body"))
        #expect(count.value == 0)

        try store.upsertMessages(accountId: "acc", [message("1", from: "a@x.com", at: 100, keywords: ["$seen"])])
        #expect(count.value > 0)
    }

    @Test func countsAndScopeKeys() throws {
        try store.upsertMessages(accountId: "acc", [
            message("1", from: "a@x.com", at: 100), message("2", from: "b@x.com", at: 200, keywords: ["$seen"]),
            message("3", from: "c@x.com", box: "tr", at: 300),
        ])
        #expect(try store.count(scope: .role("inbox"), counting: .unread) == 1)
        #expect(try store.count(scope: .role("inbox"), counting: .all) == 2)
        #expect(try store.count(scope: .account("acc"), counting: .all) == 3)
        #expect(try store.count(scope: .role("inbox"), counting: .flagged) == 0)
        #expect(try store.count(scope: .role("inbox"), counting: .unreplied) == 2)
        for scope in [MessageScope.allMessages, .flagged, .role("inbox"), .mailbox(42), .account("A:B"),
                      .flaggedInMailbox(7), .flaggedInAccount("A:B"), .allInAccount("acc")] {
            #expect(MessageScope(key: scope.key) == scope)
        }
        #expect(MessageScope(key: "mailbox:x") == nil)
    }

    @Test func search() throws {
        try store.upsertMessages(accountId: "acc", [
            message("1", from: "a@x.com", at: 100, subject: "Quarterly planning"),
            message("2", from: "b@x.com", at: 200, subject: "Lunch"),
        ])
        #expect(try store.messageIDs(scope: .allMessages, search: "quart").count == 1)
        #expect(try store.messageIDs(scope: .allMessages, search: "b@x").count == 1)
        #expect(try store.messageIDs(scope: .allMessages, search: "\"oops").isEmpty)
    }

    @Test func sortSubjectStripsReplyPrefixes() {
        #expect(MailStore.sortSubject("Re: Fwd: [3] Hello") == "[3] hello")
        #expect(MailStore.sortSubject("AW: RE[2]: Plan") == "plan")
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
