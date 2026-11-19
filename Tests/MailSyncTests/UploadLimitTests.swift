import Foundation
import JMAPKit
import MailStore
import Testing

@testable import MailSync

/// A file larger than the server takes, refused by a proxy in front of it (413 and an HTML page) or over
/// the limit its session gives: the error names the file and its size, not "not valid JMAP"; and each
/// later save of the draft doesn't upload it again only to be refused again.
@Suite struct UploadLimitTests {
    private func draft(_ server: StubJMAP.Server, size: Int) throws -> (JMAPAccountSync, OutgoingMessage) {
        let store = try MailStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try store.save(server.account)
        try store.applyMailboxes(
            accountId: server.account.id,
            upserts: [IncomingMailbox(remoteId: "D", parentRemoteId: nil, name: "Drafts", role: "drafts", sortOrder: 0, totalEmails: 0, unreadEmails: 0)],
            destroyed: [], replaceAll: true)
        let sync = try server.engine(store: store)
        var message = OutgoingMessage(
            identityId: "I", from: EmailAddress(name: "A", email: "a@x.test"), to: [EmailAddress(name: nil, email: "b@x.test")],
            cc: [], bcc: [], subject: "Re: Hello", text: "Hi")
        message.files = [OutgoingFile(name: "PastedImage.png", type: "image/png", data: Data(count: size))]
        return (sync, message)
    }

    @Test func aProxysRefusalNamesTheFile() async throws {
        let server = StubJMAP.Server(conflicts: [:], uploadLimit: 1000)
        let (sync, message) = try draft(server, size: 3000)
        for _ in 0..<2 {
            do {
                _ = try await sync.saveDraft(message, replacing: [])
                Issue.record("saved")
            } catch let error as JMAPAccountSync.SendError {
                guard case .tooLarge("PastedImage.png", 3000, nil) = error else { Issue.record("\(error)"); return }
                #expect(ErrorText.friendly(error) == "“PastedImage.png” (3 KB) is larger than the server accepts. Remove it, or attach a smaller file.")
            }
        }
        #expect(server.uploads == 1)  // the second save knew
        // Sending tries again (the limit may have been raised).
        await #expect(throws: JMAPAccountSync.SendError.self) { try await sync.send(message) }
        #expect(server.uploads == 2)
    }

    @Test func overTheSessionsLimitIsntUploaded() async throws {
        let server = StubJMAP.Server(conflicts: [:], announcedLimit: 1000)
        let (sync, message) = try draft(server, size: 3000)
        await #expect {
            _ = try await sync.saveDraft(message, replacing: [])
        } throws: { error in
            ErrorText.friendly(error) == "“PastedImage.png” (3 KB) is larger than the server accepts (up to 1 KB). Remove it, or attach a smaller file."
        }
        #expect(server.uploads == 0)
    }

    /// The session says 50 MB, a proxy refuses 3 KB: the error doesn't give the session's limit.
    @Test func aProxysLowerLimitIsntGivenAsTheSessions() async throws {
        let server = StubJMAP.Server(conflicts: [:], uploadLimit: 1000, announcedLimit: 50_000_000)
        let (sync, message) = try draft(server, size: 3000)
        await #expect {
            _ = try await sync.saveDraft(message, replacing: [])
        } throws: { error in
            ErrorText.friendly(error) == "“PastedImage.png” (3 KB) is larger than the server accepts. Remove it, or attach a smaller file."
        }
        #expect(server.uploads == 1)
    }

    @Test func underTheLimitIsSaved() async throws {
        let server = StubJMAP.Server(conflicts: [:], uploadLimit: 5000, announcedLimit: 5000)
        let (sync, message) = try draft(server, size: 3000)
        #expect(try await sync.saveDraft(message, replacing: []).hasPrefix("M"))
        #expect(server.uploads == 1)
    }

    @Test func a413ElsewhereSaysSo() {
        #expect(ErrorText.friendly(JMAPError.http(status: 413, body: "<html></html>", url: nil))
            == "The server refused the request: it’s larger than the server accepts (HTTP 413).")
    }
}
