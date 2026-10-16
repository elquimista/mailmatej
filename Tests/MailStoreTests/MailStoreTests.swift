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
