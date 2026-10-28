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

    /// Stores messages as a finished download leaves them: listed.
    func upsert(_ messages: [IncomingMessage]) throws {
        try store.upsertMessages(accountId: "acc", messages)
        let ids = try store.messageIDsByRemoteID(accountId: "acc", remoteIds: messages.map(\.remoteId))
        try store.setDownloadState(1, messageIds: Array(ids.values))
    }

    func message(_ id: String, from: String, to: String = "me@example.com", box: String = "in", at: Double,
                 subject: String = "Hello", keywords: [String] = []) -> IncomingMessage {
        IncomingMessage(
            remoteId: id, threadId: "t\(id)", blobId: "b\(id)", mailboxRemoteIds: [box], keywords: keywords, size: 100,
            receivedAt: Date(timeIntervalSince1970: at), sentAt: nil, messageIdHeader: nil, inReplyTo: nil,
            subject: subject, preview: "preview text \(id)", hasAttachment: false,
            addresses: [.init(role: .from, name: nil, email: from), .init(role: .to, name: nil, email: to)])
    }

    @Test func otherSideIsTheRecipientOfTheirMailAndTheSenderOfMine() throws {
        try upsert([
            message("1", from: "support@vendor.com", to: "alias@gmail.com", at: 100),
            message("2", from: "alias@gmail.com", to: "support@vendor.com", at: 200),
        ])
        let ids = try store.messageIDs(scope: .allMessages)  // newest first
        #expect(try store.otherSide(of: "support@vendor.com", in: ids[1]) == "alias@gmail.com")
        #expect(try store.otherSide(of: "Support@Vendor.com", in: ids[0]) == "alias@gmail.com")
    }

    @Test func toShowsAndSortsByTheRecipients() throws {
        var several = message("1", from: "me@example.com", box: "se", at: 100, subject: "Several")
        several.addresses = [
            .init(role: .from, name: nil, email: "me@example.com"), .init(role: .to, name: "Zoe", email: "zoe@x.com"),
            .init(role: .to, name: nil, email: "ann@x.com"), .init(role: .cc, name: "Cy", email: "cy@x.com"),
        ]
        var none = message("3", from: "me@example.com", box: "se", at: 300, subject: "None")
        none.addresses = [.init(role: .from, name: nil, email: "me@example.com"), .init(role: .bcc, name: nil, email: "b@x.com")]
        try upsert([
            several, message("2", from: "me@example.com", to: "Bob@X.com", box: "se", at: 200, subject: "One"), none,
        ])
        let byTo = try store.messageIDs(scope: .role("sent"), sort: MessageSort(key: .to, ascending: true))
        // No recipient first, then by the first recipient as shown, whatever its case.
        #expect(try byTo.map { try store.rows(ids: [$0]).first?.subject } == ["None", "One", "Several"])
        #expect(try store.rows(ids: byTo).map(\.toDisplay).sorted() == ["", "Zoe, ann@x.com", "bob@x.com"])
    }

    @Test func threadIdConditionFindsTheThreadAsItIsNow() throws {
        func reply(_ id: String, _ header: String, to parent: String?, at: Double) -> IncomingMessage {
            var m = message(id, from: "a@x.com", at: at, subject: "Re: plan")
            m.messageIdHeader = header
            m.inReplyTo = parent
            return m
        }
        try upsert([
            reply("1", "a@x", to: nil, at: 100), reply("2", "b@x", to: "a@x", at: 200), reply("9", "z@x", to: nil, at: 150),
        ])
        let ids = try store.messageIDs(scope: .allMessages)  // newest first: the reply, the other, the first
        let number = try store.threadNumber(of: ids[0])
        #expect(number == (try store.threadNumber(of: ids[2])))
        let condition = SmartCondition.rule(.threadId, .is, String(number))
        #expect(Set(try store.messageIDs(scope: .allMessages, search: condition)) == [ids[0], ids[2]])
        // A new reply joins the saved condition's thread.
        try upsert([reply("3", "c@x", to: "b@x", at: 300)])
        #expect(try store.messageIDs(scope: .allMessages, search: condition).count == 3)
        #expect(try store.messageIDs(scope: .allMessages, search: .rule(.threadId, .isNot, String(number))).count == 1)

        // Saved, the thread outlives its first message: the number moves to the next one.
        let saved = try store.createSmartMailbox(name: "Plan", parentId: nil)
        try store.updateSmartMailbox(id: saved, definition: SmartDefinition(condition: .compound(.all, [condition])))
        try store.deleteMessages(accountId: "acc", remoteIds: ["1"])
        #expect(try store.messageIDs(scope: .smart(saved)).count == 2)
        #expect(try store.smartMailboxes().first { $0.id == saved }?.definition.condition.threadNumbers
            == [try store.threadNumber(of: ids[0])])
    }

    @Test func duplicatingASmartMailboxCopiesItRightAfterIt() throws {
        let first = try store.createSmartMailbox(name: "Credit", parentId: nil)
        let second = try store.createSmartMailbox(name: "Other", parentId: nil)
        var definition = SmartDefinition(sources: SmartSources(scopes: ["role:inbox"]))
        definition.condition = .compound(.all, [.rule(.fromDomain, .is, "payoneer.com")])
        try store.updateSmartMailbox(id: first, definition: definition)
        let copy = try #require(try store.duplicateSmartMailbox(id: first))
        let all = try store.smartMailboxes().filter { $0.parentId == nil }.sorted { $0.sortOrder < $1.sortOrder }
        #expect(all.map(\.id) == [first, copy, second])
        #expect(all[1].name == "Credit copy")
        #expect(all[1].definition == definition)
    }

    @Test func dateConditionsMatchPeriodsAndParts() throws {
        func at(_ text: String) -> Double { try! Date(text, strategy: .iso8601).timeIntervalSince1970 }
        var early = message("1", from: "a@x.com", at: at("2023-12-31T23:30:00Z"))
        early.sentAt = Date(timeIntervalSince1970: at("2023-12-31T23:30:00Z"))
        early.sentZone = 120  // 01:30 on 1 January 2024 for the sender, at +0200
        var late = message("2", from: "b@x.com", at: at("2024-03-15T12:00:00Z"))
        late.sentAt = Date(timeIntervalSince1970: at("2024-03-15T12:00:00Z"))
        late.sentZone = -300
        try upsert([early, late])
        let ids = try store.messageIDs(scope: .allMessages, sort: MessageSort(key: .receivedAt, ascending: true))
        func matching(_ field: SmartField, _ op: SmartOperator, _ value: String = "") throws -> [Int64] {
            let id = try store.createSmartMailbox(name: "\(field.rawValue) \(op)", parentId: nil)
            var definition = SmartDefinition(sources: SmartSources(scopes: ["all"]))
            definition.condition = .compound(.all, [.rule(field, op, value)])
            try store.updateSmartMailbox(id: id, definition: definition)
            return try store.messageIDs(scope: .smart(id), sort: MessageSort(key: .receivedAt, ascending: true))
        }
        // Periods are this Mac's days and months; mid-March is clear of any time zone's edge.
        #expect(try matching(.date, .isExactly, "2024-03") == [ids[1]])
        #expect(try matching(.date, .isExactly, "15.03.2024") == [ids[1]])
        #expect(try matching(.date, .isAfter, "2024-02") == [ids[1]])
        #expect(try matching(.date, .isBefore, "2024-03-15") == [ids[0]])
        #expect(try matching(.date, .exists) == ids)
        #expect(try matching(.dateLocal, .isExactly, "2024-03") == [ids[1]])
        #expect(try matching(.date, .isBefore, "not a date").isEmpty)
        // Parts are in the sender's time zone, as written in its Date header.
        #expect(try matching(.datePart(.year, local: false), .is, "2024") == ids)
        #expect(try matching(.datePart(.day, local: false), .is, "2024-01-01") == [ids[0]])
        #expect(try matching(.datePart(.zone, local: false), .is, "-0500") == [ids[1]])
        #expect(try matching(.datePart(.formatted, local: false), .contains, "07:00:00 -0500") == [ids[1]])
        #expect(try matching(.datePart(.month, local: false), .moreOrEqual, "2024-02") == [ids[1]])
        #expect(try store.fieldValues(.datePart(.year, local: false), sources: SmartSources(scopes: ["all"])) == ["2024"])
        #expect(MailStore.datePeriod("2024-02-30") == nil)
    }

    @Test func dateMeansWhenTheMessageArrived() throws {
        // Written (its Date header) in December, delivered in March: Date is March.
        var delayed = message("1", from: "a@x.com", at: try Date("2024-03-20T12:00:00Z", strategy: .iso8601).timeIntervalSince1970)
        delayed.sentAt = try Date("2023-12-20T12:00:00Z", strategy: .iso8601)
        try upsert([delayed])
        let id = try store.createSmartMailbox(name: "March", parentId: nil)
        var definition = SmartDefinition(sources: SmartSources(scopes: ["all"]))
        definition.condition = .compound(.all, [.rule(.date, .isExactly, "2024-03"), .rule(.datePart(.year, local: true), .is, "2024")])
        try store.updateSmartMailbox(id: id, definition: definition)
        #expect(try store.messageIDs(scope: .smart(id)).count == 1)
    }

    @Test func messagesAnsweringTheSameMissingMessageThreadByArrival() {
        // A Zendesk ticket: each message "replies" to the ticket's id, which no message has.
        let rows = [
            MailStore.ThreadInput(id: 3, account: "a", at: 300, seen: false, messageId: "c@z", inReplyTo: "ticket@z"),
            MailStore.ThreadInput(id: 1, account: "a", at: 100, seen: false, messageId: "a@z", inReplyTo: "ticket@z"),
            MailStore.ThreadInput(id: 2, account: "a", at: 200, seen: false, messageId: "b@z", inReplyTo: "ticket@z"),
            MailStore.ThreadInput(id: 4, account: "a", at: 400, seen: false, messageId: "d@z", inReplyTo: "other@z"),
        ]
        #expect(MailStore.parents(rows) == [2: 1, 3: 2])
        let threaded = MailStore.thread(rows, expanded: ["a:1"], opened: [2])
        #expect(threaded.first { $0.id == 1 }?.size == 3)
        #expect(threaded.map { "\($0.id):\($0.depth)" }.contains("3:2"))
    }

    @Test func quotedTextSplitsPlainAndHTML() {
        let plain = QuotedText.split(plain: "Sounds good.\n\nOn 1 Oct, Ann wrote:\n> invoice attached\n>> older")
        #expect(plain.unquoted == "Sounds good.\n\nOn 1 Oct, Ann wrote:")
        #expect(plain.quoted == "invoice attached\nolder")
        let html = QuotedText.split(
            html: "<p>Sounds good.</p><blockquote><p>invoice attached</p><blockquote>older</blockquote> tail</blockquote><p>Bye</p>")
        #expect(html.unquoted == "Sounds good.\nBye")
        #expect(html.quoted.contains("invoice attached") && html.quoted.contains("older") && html.quoted.contains("tail"))
        #expect(!html.unquoted.contains("invoice"))
    }

    @Test func unquotedAndQuotedTextConditionsSearchTheirParts() throws {
        try upsert([
            message("1", from: "a@x.com", at: 100, subject: "Re: plan"), message("2", from: "b@x.com", at: 200, subject: "Invoice"),
        ])
        let ids = try store.messageIDs(scope: .allMessages, sort: MessageSort(key: .receivedAt, ascending: true))
        try store.saveBody(messageId: ids[0], MessageBody(html: nil, text: "Sounds good.\n> the invoice is attached"))
        try store.saveBody(messageId: ids[1], MessageBody(html: "<p>Here is the invoice.</p>", text: nil))
        // Indexed text survives the message being updated again (a flag change).
        try upsert([message("1", from: "a@x.com", at: 100, subject: "Re: plan", keywords: ["$seen"])])
        func matching(_ field: SmartField) throws -> [Int64] {
            let id = try store.createSmartMailbox(name: field.rawValue, parentId: nil)
            var definition = SmartDefinition(sources: SmartSources(scopes: ["all"]))
            definition.condition = .compound(.all, [.rule(field, .contains, "invoice")])
            try store.updateSmartMailbox(id: id, definition: definition)
            return try store.messageIDs(scope: .smart(id), sort: MessageSort(key: .receivedAt, ascending: true))
        }
        #expect(try matching(.unquoted) == [ids[1]])  // only the second wrote it (HTML-only, indexed too)
        #expect(try matching(.quoted) == [ids[0]])  // the first only quotes it
        #expect(try matching(.body) == ids)  // Message Text: both, as before
        #expect(try matching(.headersOrUnquoted) == [ids[1]])
    }

    @Test func specialMailboxesPlacedInASmartMailboxCountAsItsSubmailboxes() throws {
        try upsert([
            message("1", from: "a@x.com", at: 100), message("2", from: "me@example.com", box: "se", at: 200),
        ])
        // A smart mailbox with no mailboxes of its own, including its submailboxes.
        let id = try store.createSmartMailbox(name: "Mine", parentId: nil)
        try store.updateSmartMailbox(id: id, definition: SmartDefinition(sources: SmartSources(scopes: [], includeSubmailboxes: true)))
        #expect(try store.messageIDs(scope: .smart(id)).isEmpty)
        try store.placeSpecialMailbox(key: "role:sent", inside: id, index: 0)
        #expect(try store.specialPlacements().map(\.key) == ["role:sent"])
        #expect(try store.messageIDs(scope: .smart(id)).count == 1)  // Sent's message
        try store.placeSpecialMailbox(key: "role:inbox", inside: id, index: 0)
        #expect(try store.specialPlacements().map(\.key) == ["role:inbox", "role:sent"])  // in the order placed
        #expect(try store.messageIDs(scope: .smart(id)).count == 2)
        // Back at the top, and gone with the smart mailbox.
        try store.placeSpecialMailbox(key: "role:inbox", inside: nil, index: 0)
        #expect(try store.messageIDs(scope: .smart(id)).count == 1)
        try store.deleteSmartMailbox(id: id)
        #expect(try store.specialPlacements().isEmpty)
    }

    @Test func smartMailboxesMatchTheirConditions() throws {
        try upsert([
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
        try upsert([a, b])
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
        // A special mailbox's submailboxes by value: Inbox by From ‣ Name, and within an account.
        #expect(try store.values(of: .fromName, in: .role("inbox")).map(\.value) == ["Ann Lee", ""])
        let byName = MessageScope.value(.role("inbox"), .fromName, "Ann Lee")
        #expect(try store.rows(ids: try store.messageIDs(scope: byName)).map(\.subject) == ["One"])
        #expect(MessageScope(key: MessageScope.value(.role("inbox"), .fromName, "A|B: C").key) == .value(.role("inbox"), .fromName, "A|B: C"))
        #expect(try store.values(of: .keyword, in: .allInAccount("acc")).map(\.value) == ["$label1"])
        #expect(try store.values(of: .keyword, in: .allInAccount("other")).isEmpty)
        // Date's parts that group mail split too, and Content-Type; Time and Formatted don't.
        #expect(MailStore.canSplit(by: .datePart(.year, local: true)) && MailStore.canSplit(by: .contentTypeType))
        #expect(!MailStore.canSplit(by: .datePart(.time, local: false)) && !MailStore.canSplit(by: .date))
        let years = try store.values(of: .datePart(.year, local: true), in: .allMessages)
        #expect(years.count == 2)
        #expect(try store.messageIDs(scope: .value(.allMessages, .datePart(.year, local: true), years[1].value)).count == 1)
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
        try upsert([
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

    @Test func specialMailboxConditionsNarrowThemAndTheirSubmailboxes() throws {
        try upsert([
            message("1", from: "news@shop.com", at: 100, subject: "Sale"),
            message("2", from: "ann@x.com", at: 200, subject: "Lunch"),
        ])
        let inbox = try #require(try store.mailbox(accountId: "acc", role: "inbox"))
        #expect(try store.messageIDs(scope: .role("inbox")).count == 2)
        try store.setSpecialCondition(.compound(.none, [.rule(.fromDomain, .is, "shop.com")]), key: "role:inbox")
        #expect(store.hasSpecialCondition(key: "role:inbox"))
        #expect(try store.rows(ids: try store.messageIDs(scope: .role("inbox"))).map(\.subject) == ["Lunch"])
        // Its submailbox (the account's Inbox) is narrowed too; the account's folder itself isn't.
        let child = MessageScope.within("role:inbox", .mailbox(inbox.id))
        #expect(MessageScope(key: child.key) == child)
        #expect(try store.messageIDs(scope: child).count == 1)
        #expect(try store.messageIDs(scope: .mailbox(inbox.id)).count == 2)
        // A condition naming its own mailbox doesn't loop.
        try store.setSpecialCondition(.compound(.all, [.rule(.mailbox, .is, "role:inbox")]), key: "role:inbox")
        #expect(try store.messageIDs(scope: .role("inbox")).count == 2)
        try store.setSpecialCondition(.compound(.all, []), key: "role:inbox")
        #expect(!store.hasSpecialCondition(key: "role:inbox"))
    }

    @Test func noMailboxesMeansNoMessages() throws {
        try upsert([message("1", from: "a@x.com", at: 100)])
        let id = try store.createSmartMailbox(name: "New", parentId: nil)  // MailMate's new one: no mailboxes
        #expect(try store.messageIDs(scope: .smart(id)).isEmpty)
        try store.updateSmartMailbox(id: id, definition: SmartDefinition(sources: SmartSources(scopes: ["all"])))
        #expect(try store.messageIDs(scope: .smart(id)).count == 1)
    }

    @Test func smartMailboxesInsideSpecialOnes() throws {
        try upsert([message("1", from: "a@x.com", at: 100), message("2", from: "b@x.com", box: "tr", at: 200)])
        let id = try store.createSmartMailbox(name: "In All", parentId: nil, parentKey: "all")
        let record = try #require(try store.smartMailboxes().first { $0.id == id })
        #expect(record.parentKey == "all" && record.definition.sources.scopes == ["all"])  // starts from All Messages
        #expect(try store.messageIDs(scope: .smart(id)).count == 1)  // not the one in Deleted Messages
        try store.moveSmartMailbox(id: id, toParent: nil, parentKey: "role:inbox", index: 0)
        #expect(try store.smartMailboxes().first { $0.id == id }?.parentKey == "role:inbox")
        try store.moveSmartMailbox(id: id, toParent: nil, index: 0)  // back to the top level
        #expect(try store.smartMailboxes().first { $0.id == id }?.parentKey == nil)
    }

    @Test func smartMailboxesMoveAndNest() throws {
        let a = try store.createSmartMailbox(name: "A", parentId: nil)
        let b = try store.createSmartMailbox(name: "B", parentId: nil)
        let c = try store.createSmartMailbox(name: "C", parentId: nil)
        try store.moveSmartMailbox(id: c, toParent: nil, index: 0)
        #expect(try store.smartMailboxes().filter { $0.parentId == nil }.map(\.name) == ["C", "A", "B"])
        try store.moveSmartMailbox(id: a, toParent: b, index: 0)  // into B
        #expect(try store.smartMailboxes().first { $0.id == a }?.parentId == b)
        try store.moveSmartMailbox(id: b, toParent: a, index: 0)  // not into its own child
        #expect(try store.smartMailboxes().first { $0.id == b }?.parentId == nil)
    }

    @Test func scopesAndOrdering() throws {
        try upsert([
            message("1", from: "a@x.com", at: 100),
            message("2", from: "b@x.com", box: "tr", at: 200),
            message("3", from: "c@x.com", at: 300, keywords: ["$flagged", "$seen"]),
        ])
        let inbox = try store.messageIDs(scope: .role("inbox"))
        #expect(inbox.count == 2)
        #expect(try store.rows(ids: [inbox[0]]).first?.fromEmail == "c@x.com")  // newest first
        #expect(try store.messageIDs(scope: .allMessages).count == 2)  // trash excluded
        #expect(try store.messageIDs(scope: .everything).count == 3)  // All / Junk / Deleted: trash too
        #expect(MessageScope(key: MessageScope.everything.key) == .everything)
        #expect(try store.messageIDs(scope: .flagged).count == 1)
        let bySubject = try store.messageIDs(scope: .role("inbox"), sort: MessageSort(key: .from, ascending: true))
        #expect(try store.newestMessageID(scope: .role("inbox")) == bySubject.last)  // c@x.com, newest
        #expect(try store.rows(ids: inbox).first { $0.fromEmail == "c@x.com" }?.isSeen == true)
    }

    @Test func upsertUpdatesInPlaceAndDeleteCascades() throws {
        try upsert([message("1", from: "a@x.com", at: 100)])
        let id = try #require(store.messageIDs(scope: .allMessages).first)
        try upsert([message("1", from: "a@x.com", box: "tr", at: 100, keywords: ["$seen"])])
        #expect(try store.messageIDs(scope: .allMessages).isEmpty)
        #expect(try store.messageIDs(scope: .role("trash")) == [id])  // same local id

        try store.deleteMessages(accountId: "acc", remoteIds: ["1"])
        #expect(try store.messageIDs(scope: .account("acc")).isEmpty)
        #expect(try store.correspondenceIDs(email: "a@x.com").isEmpty)
        #expect(try store.messageIDs(scope: .account("acc"), search: .quickSearch("preview")).isEmpty)
    }

    @Test func correspondence() throws {
        try upsert([
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
        try upsert([message("4", from: "ada@x.com", box: "tr", at: 400)])
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

    @Test func contentTypeConditionsTestTheMessagesParts() throws {
        try upsert([
            message("1", from: "notifications@calendly.com", at: 100), message("2", from: "a@x.com", at: 200),
        ])
        let ids = try store.messageIDs(scope: .allMessages)  // newest first
        try store.saveBody(messageId: ids[1], MessageBody(html: nil, text: "Invite"), parts: [
            MessagePart(blobId: "c", cid: nil, type: "text/calendar", name: "invite.ics", size: 10),
        ])
        try store.saveBody(messageId: ids[0], MessageBody(html: nil, text: "Logo"), parts: [
            MessagePart(blobId: "p", cid: nil, type: "image/png", name: nil, size: 10),
        ])
        func find(_ field: SmartField, _ op: SmartOperator, _ value: String) throws -> [Int64] {
            try store.messageIDs(scope: .allMessages, search: .rule(field, op, value))
        }
        #expect(try find(.contentTypeSubtype, .is, "Calendar") == [ids[1]])
        #expect(try find(.contentTypeType, .is, "image") == [ids[0]])
        #expect(try find(.contentType, .is, "text/calendar") == [ids[1]])
        #expect(try find(.contentTypeName, .endsWith, ".ics") == [ids[1]])
        #expect(try find(.contentTypeSubtype, .isNot, "calendar") == [ids[0]])
        #expect(try store.fieldValues(.contentTypeSubtype, sources: SmartSources()) == ["calendar", "png"])
    }

    @Test func mailboxListsBringInAccountsAsTheirMatchSays() {
        // Busy: Gmail's account, which AGENT-095 (a smart mailbox) brings in.
        let leaf: (String) -> Set<String>? = { key in
            switch key {
            case "account:gmail", "smart:95": ["gmail"]
            case "account:alice": []  // names an account, not a busy one
            default: nil  // names none: Inbox, All Messages
            }
        }
        func rule(_ key: String, _ op: SmartOperator = .is) -> SmartCondition { .rule(.mailbox, op, key) }
        // Imbox: All of [Other ▸ Inbox, None of [AGENT-095]]: Gmail's mail stays out.
        let imbox = SmartSources(root: .compound(.all, [rule("within:role:inbox|smart:7"), .compound(.none, [rule("smart:95")])]))
        #expect(imbox.accounts(bringingIn: leaf).isEmpty)
        #expect(SmartSources(root: .compound(.any, [rule("role:inbox"), rule("smart:95")])).accounts(bringingIn: leaf) == ["gmail"])
        #expect(SmartSources(root: .compound(.all, [rule("account:gmail"), rule("smart:95")])).accounts(bringingIn: leaf) == ["gmail"])
        // Inbox names no account, so it doesn't limit an All: AGENT-095 (All of [Inbox, the group]) spins.
        #expect(SmartSources(root: .compound(.all, [rule("account:gmail"), rule("role:inbox")])).accounts(bringingIn: leaf) == ["gmail"])
        #expect(SmartSources(root: .compound(.all, [rule("role:inbox"), rule("smart:95")])).accounts(bringingIn: leaf) == ["gmail"])
        // An account that isn't busy does: only its mail.
        #expect(SmartSources(root: .compound(.all, [rule("account:alice"), rule("smart:95")])).accounts(bringingIn: leaf).isEmpty)
        #expect(SmartSources(root: .compound(.any, [rule("role:inbox")])).namedAccounts(bringingIn: leaf) == nil)
        #expect(SmartSources(root: .compound(.any, [rule("account:gmail", .isNot)])).accounts(bringingIn: leaf).isEmpty)
        #expect(SmartSources(root: .compound(.any, [.rule(.mailbox, .is, "account:gmail", enabled: false)])).accounts(bringingIn: leaf).isEmpty)
    }

    @Test func theFullNameIsTheIdentitiesName() throws {
        try store.replaceIdentities(accountId: "acc", [
            ("1", "Contact@x.com", "contact@x.com"), ("2", "", "me@example.com"), ("3", "Ada", "ada@x.com"),
        ])
        func names() throws -> [String: String] { Dictionary(uniqueKeysWithValues: try store.identities().map { ($0.email, $0.name) }) }
        #expect(try names() == ["contact@x.com": "Contact@x.com", "me@example.com": "", "ada@x.com": "Ada"])  // no Full Name
        var named = account
        named.fullName = "SHS Home"
        try store.save(named)
        #expect(try names() == ["contact@x.com": "SHS Home", "me@example.com": "SHS Home", "ada@x.com": "SHS Home"])
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

    @Test func threadsMarkAFlaggedReplyOnTheMessagesAboveIt() {
        typealias T = MailStore.ThreadInput
        // a, answered by b (flagged), answered by c; d answers a too. The first message is flagged in e's thread.
        let rows = [
            T(id: 1, at: 10, seen: true, messageId: "a"), T(id: 2, at: 20, seen: true, flagged: true, messageId: "b", inReplyTo: "a"),
            T(id: 3, at: 30, seen: true, messageId: "c", inReplyTo: "b"), T(id: 4, at: 40, seen: true, messageId: "d", inReplyTo: "a"),
            T(id: 5, at: 50, seen: true, flagged: true, messageId: "e"), T(id: 6, at: 60, seen: true, messageId: "f", inReplyTo: "e"),
        ]
        let keys = MailStore.threadKeys(rows)
        let flagged = { (rows: [MailStore.ThreadedRow]) in rows.filter(\.flaggedReply).map(\.id) }
        #expect(flagged(MailStore.thread(rows, expanded: [])) == [1])  // e's own flag isn't a reply's
        #expect(flagged(MailStore.thread(rows, expanded: [keys[1]!])) == [1])  // b's flag is its own
        // Under b, c isn't flagged; nothing under d.
        #expect(flagged(MailStore.thread(rows, expanded: [keys[1]!], opened: [2])) == [1])
        let unflagged = rows.map { var row = $0; row.flagged = row.id == 3; return row }
        #expect(flagged(MailStore.thread(unflagged, expanded: [keys[1]!])) == [1, 2])  // c, under b
        // And how many replies each stands for: b, c and d under a; c under b.
        #expect(MailStore.thread(rows, expanded: [keys[1]!]).map(\.replyCount) == [3, 1, 0, 1])
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
        try upsert([
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
        try upsert([
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
        try upsert([message("1", from: "a@x.com", at: 100)])
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

    @Test func downloadedMessagesShowUpAndEchoesWriteNothing() throws {
        try store.upsertMessages(accountId: "acc", [message("1", from: "a@x.com", at: 100)])
        let id = try #require(store.messageIDsByRemoteID(accountId: "acc", remoteIds: ["1"])["1"])
        let count = Counter()
        let observation = store.observeChanges { count.increment() }
        defer { observation.cancel() }

        // Its body is bookkeeping; being downloaded shows it.
        try store.saveBody(messageId: id, MessageBody(html: nil, text: "full body"))
        #expect(count.value == 0)
        try store.setDownloadState(1, messageIds: [id])
        #expect(count.value == 1)

        // The server reporting it unchanged (an echo of a change made here) writes nothing.
        try store.upsertMessages(accountId: "acc", [message("1", from: "a@x.com", at: 100)])
        #expect(count.value == 1)
        try store.setKeyword("$seen", true, messageIds: [id])
        #expect(count.value == 2)
        try store.upsertMessages(accountId: "acc", [message("1", from: "a@x.com", at: 100, keywords: ["$seen"])])
        #expect(count.value == 2)
        // Its downloaded text stays searchable through it all.
        #expect(try store.messageIDs(scope: .allMessages, search: .quickSearch("full body")) == [id])

        // A change made elsewhere comes through: the keyword, and new addresses (searchable).
        try store.upsertMessages(accountId: "acc", [message("1", from: "a@x.com", to: "zed@x.com", at: 100)])
        #expect(count.value == 3)
        #expect(try store.unreadIDs(scope: .allMessages) == [id])
        #expect(try store.messageIDs(scope: .allMessages, search: .quickSearch("zed")) == [id])
        #expect(try store.messageIDs(scope: .allMessages, search: .quickSearch("full body")) == [id])
    }

    @Test func mailboxCountsFollowChangesMadeHere() throws {
        try upsert([
            message("1", from: "a@x.com", at: 100), message("2", from: "b@x.com", at: 200, keywords: ["$seen"]),
            message("3", from: "c@x.com", box: "tr", at: 300),
        ])
        try store.recountMailboxes(accountId: "acc")  // as the server counts them
        let ids = try store.messageIDsByRemoteID(accountId: "acc", remoteIds: ["1", "2", "3"])
        let boxes = Dictionary(uniqueKeysWithValues: try store.mailboxes().map { ($0.remoteId, $0.id) })
        func counts() throws -> [String: [Int]] {
            Dictionary(uniqueKeysWithValues: try store.mailboxes().map { ($0.remoteId, [$0.totalEmails, $0.unreadEmails]) })
        }
        /// The counts as changed here, and as a recount from the messages has them, after `change`.
        func expectRecounted(_ change: () throws -> Void, _ expected: [String: [Int]]) throws {
            try change()
            let changed = try counts()
            try store.recountMailboxes(accountId: "acc")
            #expect(changed == expected)
            #expect(try counts() == expected)
        }
        try expectRecounted({ try store.setKeyword("$seen", true, messageIds: [ids["1"]!]) },
                            ["in": [2, 0], "tr": [1, 1], "se": [0, 0]])
        try expectRecounted({ try store.setKeyword("$seen", false, messageIds: [ids["1"]!, ids["2"]!]) },
                            ["in": [2, 2], "tr": [1, 1], "se": [0, 0]])
        try expectRecounted({ try store.moveMessages([ids["1"]!, ids["3"]!], toMailboxId: boxes["se"]!) },
                            ["in": [1, 1], "tr": [0, 0], "se": [2, 2]])
        try expectRecounted({ try store.setMailboxes([ids["1"]!: [boxes["in"]!, boxes["tr"]!], ids["2"]!: []]) },
                            ["in": [1, 1], "tr": [1, 1], "se": [1, 1]])
    }

    @Test func countsOfAFewMessagesPerList() throws {
        try upsert([
            message("1", from: "a@payoneer.com", at: 100), message("2", from: "b@x.com", at: 200),
            message("3", from: "c@payoneer.com", box: "tr", at: 300),
        ])
        let ids = try store.messageIDsByRemoteID(accountId: "acc", remoteIds: ["1", "2", "3"])
        let payoneer = try store.createSmartMailbox(name: "Payoneer", parentId: nil)
        var definition = SmartDefinition(sources: SmartSources(scopes: [MessageScope.allMessages.key]))
        definition.condition = .compound(.all, [.rule(.fromDomain, .is, "payoneer.com")])
        try store.updateSmartMailbox(id: payoneer, definition: definition)
        let unread = try store.createSmartMailbox(name: "Unread", parentId: nil)
        definition.condition = .compound(.all, [.rule(.status, .is, SmartStatus.unread.rawValue)])
        try store.updateSmartMailbox(id: unread, definition: definition)

        let all = [ids["1"]!, ids["2"]!, ids["3"]!]
        // Trash is outside All Messages; a list picking messages by being read can't be worked out so.
        #expect(try store.counts(of: all, in: [.smart(payoneer), .allMessages, .role("trash"), .smart(unread)])
            == [1, 2, 1, nil])
        #expect(try store.counts(of: [ids["2"]!], in: [.smart(payoneer), .everything]) == [0, 1])
    }

    @Test func keywordsAndMailboxesByRemoteID() throws {
        try upsert([message("1", from: "a@x.com", at: 100, keywords: ["$seen", "$answered"]), message("2", from: "b@x.com", at: 200)])
        var state = try store.keywordsAndMailboxes(accountId: "acc", remoteIds: ["1", "2", "gone"])
        #expect(state["1"]?.keywords == ["$seen", "$answered"] && state["1"]?.mailboxes == ["in"])
        #expect(state["2"]?.keywords == [] && state["gone"] == nil)

        let count = Counter()
        let observation = store.observeChanges { count.increment() }
        defer { observation.cancel() }
        // Unread and flagged, into Trash; keywords not managed ($answered) stay.
        try store.setKeywordsAndMailboxes(
            accountId: "acc", ["1": (["$flagged"], ["tr"]), "2": ([], ["in"])], among: ["$seen", "$flagged"])
        state = try store.keywordsAndMailboxes(accountId: "acc", remoteIds: ["1", "2"])
        #expect(state["1"]?.keywords == ["$flagged", "$answered"] && state["1"]?.mailboxes == ["tr"])
        let ids = try store.messageIDsByRemoteID(accountId: "acc", remoteIds: ["1"])
        #expect(try store.marks(ids: [ids["1"]!]).first.map { [$0.seen, $0.flagged] } == [false, true])
        #expect(count.value == 1)
        // Nothing different: nothing written.
        try store.setKeywordsAndMailboxes(accountId: "acc", ["2": ([], ["in"])], among: ["$seen", "$flagged"])
        #expect(count.value == 1)
    }

    @Test func messagesShowOnceDownloaded() throws {
        try store.upsertMessages(accountId: "acc", [message("1", from: "a@x.com", at: 100), message("2", from: "b@x.com", at: 200)])
        let ids = try store.messageIDsByRemoteID(accountId: "acc", remoteIds: ["1", "2"])
        #expect(try store.messageIDs(scope: .allMessages).isEmpty)
        #expect(try store.count(scope: .role("inbox"), counting: .unread) == 0)
        #expect(try store.downloadCounts(scope: .allMessages) == (0, 2))

        try store.setDownloadState(1, messageIds: [ids["2"]!])
        #expect(try store.messageIDs(scope: .allMessages) == [ids["2"]!])
        #expect(try store.count(scope: .role("inbox"), counting: .unread) == 1)
        #expect(try store.correspondenceIDs(email: "a@x.com").isEmpty)
        // One that couldn't be downloaded shows as far as it's known.
        try store.setDownloadState(2, messageIds: [ids["1"]!])
        #expect(try store.messageIDs(scope: .allMessages) == [ids["2"]!, ids["1"]!])
        #expect(try store.correspondenceIDs(email: "a@x.com") == [ids["1"]!])
        #expect(try store.downloadCounts(scope: .allMessages) == (1, 2))
    }

    @Test func countsAndScopeKeys() throws {
        try upsert([
            message("1", from: "a@x.com", at: 100), message("2", from: "b@x.com", at: 200, keywords: ["$seen"]),
            message("3", from: "c@x.com", box: "tr", at: 300),
        ])
        #expect(try store.count(scope: .role("inbox"), counting: .unread) == 1)
        #expect(try store.count(scope: .role("inbox"), counting: .all) == 2)
        #expect(try store.count(scope: .account("acc"), counting: .all) == 3)
        #expect(try store.count(scope: .role("inbox"), counting: .flagged) == 0)
        #expect(try store.count(scope: .role("inbox"), counting: .unreplied) == 2)
        // A mailbox with its submailboxes: each message once, also where the lists overlap.
        #expect(try store.count(scopes: [.role("inbox"), .account("acc")], counting: .all) == 3)
        #expect(try store.count(scopes: [.role("inbox"), .role("trash")], counting: .unread) == 2)
        for scope in [MessageScope.allMessages, .flagged, .role("inbox"), .mailbox(42), .account("A:B"),
                      .flaggedInMailbox(7), .flaggedInAccount("A:B"), .allInAccount("acc")] {
            #expect(MessageScope(key: scope.key) == scope)
        }
        #expect(MessageScope(key: "mailbox:x") == nil)
    }

    @Test func search() throws {
        try upsert([
            message("1", from: "a@x.com", at: 100, subject: "Quarterly planning"),
            message("2", from: "b@x.com", at: 200, subject: "Lunch"),
        ])
        #expect(try store.messageIDs(scope: .allMessages, search: .quickSearch("quart")).count == 1)
        #expect(try store.messageIDs(scope: .allMessages, search: .quickSearch("b@x")).count == 1)
        #expect(try store.messageIDs(scope: .allMessages, search: .quickSearch("\"oops")).isEmpty)
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
