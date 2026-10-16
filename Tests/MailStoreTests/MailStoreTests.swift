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
        #expect(try store.count(scope: .role("inbox"), unreadOnly: true) == 1)
        #expect(try store.count(scope: .role("inbox"), unreadOnly: false) == 2)
        #expect(try store.count(scope: .account("acc"), unreadOnly: false) == 3)
        for scope in [MessageScope.allMessages, .flagged, .role("inbox"), .mailbox(42), .account("A:B")] {
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
