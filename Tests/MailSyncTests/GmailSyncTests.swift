import Foundation
import GmailKit
import MailStore
import Testing

@testable import MailSync

@Suite struct GmailSyncTests {
    private func message(_ json: String) throws -> GmailClient.Message {
        try JSONDecoder().decode(GmailClient.Message.self, from: Data(json.utf8))
    }

    private func b64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    @Test func mapsLabelsHeadersAndFlags() throws {
        let m = try message("""
            {"id": "18c1", "threadId": "18c0", "labelIds": ["INBOX", "STARRED", "Label_7", "CATEGORY_UPDATES"],
             "snippet": "Don&#39;t forget", "internalDate": "1700000000000", "sizeEstimate": 2048,
             "payload": {"mimeType": "multipart/mixed", "headers": [
               {"name": "From", "value": "=?UTF-8?Q?Jos=C3=A9?= <jose@x.com>"},
               {"name": "To", "value": "me@gmail.com, undisclosed-recipients:;"},
               {"name": "Subject", "value": "Plans"},
               {"name": "Date", "value": "Tue, 14 Nov 2023 23:13:20 +0100"},
               {"name": "Message-ID", "value": "<a@x.com>"},
               {"name": "References", "value": "<r1@x> <r2@x>"},
               {"name": "In-Reply-To", "value": "<r2@x>"}]}}
            """)
        let incoming = try #require(GmailAccountSync.incoming(m, mailboxLabels: ["INBOX", "Label_7", "TRASH"]))
        #expect(Set(incoming.mailboxRemoteIds) == ["INBOX", "Label_7"])
        // Archived: by MailMate's label, or with no label at all.
        let archived = try message(#"{"id": "a", "labelIds": ["Label_9", "IMPORTANT"]}"#)
        #expect(GmailAccountSync.incoming(archived, mailboxLabels: ["INBOX"], archiveLabel: "Label_9")?.mailboxRemoteIds == ["ARCHIVE"])
        let unlabelled = try message(#"{"id": "u", "labelIds": ["CATEGORY_UPDATES"]}"#)
        #expect(GmailAccountSync.incoming(unlabelled, mailboxLabels: ["INBOX"])?.mailboxRemoteIds == ["ARCHIVE"])
        #expect(Set(incoming.keywords) == ["$seen", "$flagged"])  // no UNREAD label: read
        #expect(incoming.addresses.first?.name == "José" && incoming.addresses.first?.email == "jose@x.com")
        #expect(incoming.addresses.contains { $0.role == .toGroup && $0.name == "undisclosed-recipients" })
        #expect(incoming.preview == "Don't forget" && incoming.size == 2048 && incoming.hasAttachment)
        #expect(incoming.receivedAt == Date(timeIntervalSince1970: 1_700_000_000) && incoming.sentZone == 60)
        #expect(incoming.messageIdHeader == "a@x.com" && incoming.inReplyTo == "r2@x" && incoming.references == ["r1@x", "r2@x"])

        let spam = try message(#"{"id": "s", "labelIds": ["SPAM", "UNREAD"], "payload": {"mimeType": "text/plain", "headers": []}}"#)
        let stored = try #require(GmailAccountSync.incoming(spam, mailboxLabels: ["SPAM"]))
        #expect(stored.mailboxRemoteIds == ["SPAM"] && stored.keywords.isEmpty && !stored.hasAttachment)
        #expect(GmailAccountSync.incoming(try message(#"{"id": "c", "labelIds": ["CHAT"]}"#), mailboxLabels: []) == nil)
    }

    /// A raw message: Gmail's typical shape, with a related picture, a PDF and an unnamed invite.
    static let raw = """
        From: Ann <ann@x.com>\r
        Subject: Invite\r
        Content-Type: multipart/mixed; boundary="mixed"\r
        \r
        preamble\r
        --mixed\r
        Content-Type: multipart/related; boundary=rel\r
        \r
        --rel\r
        Content-Type: multipart/alternative; boundary="alt"\r
        \r
        --alt\r
        Content-Type: text/plain; charset=ISO-8859-1\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        Caf=E9 at noon, a long line that wraps with a soft =\r
        break.\r
        --alt\r
        Content-Type: text/html; charset=UTF-8\r
        Content-Transfer-Encoding: base64\r
        \r
        PHA+Q2Fmw6kgPGltZyBzcmM9ImNpZDpsb2dvQHgiPjwvcD4=\r
        --alt--\r
        --rel\r
        Content-Type: image/png; name="logo.png"\r
        Content-ID: <logo@x>\r
        Content-Transfer-Encoding: base64\r
        \r
        iVBORw0KGgo=\r
        --rel--\r
        --mixed\r
        Content-Type: application/pdf; name="bill.pdf"\r
        Content-Disposition: attachment; filename="bill.pdf"\r
        Content-Transfer-Encoding: base64\r
        \r
        JVBERi0xLjQ=\r
        --mixed\r
        Content-Type: text/calendar; method=REQUEST; charset=UTF-8\r
        \r
        BEGIN:VCALENDAR\r
        --mixed--\r
        epilogue\r

        """

    @Test func picksBodiesAndAttachmentsAsJMAPDoes() throws {
        let structure = BodyStructure(MIMEPart.parse(Data(Self.raw.utf8)))
        #expect(structure.textBody.map(\.type) == ["text/plain"])
        #expect(structure.htmlBody.map(\.type) == ["text/html"])
        // The related picture (not first in multipart/related), the PDF and the unnamed invite.
        #expect(structure.attachments.map(\.type) == ["image/png", "application/pdf", "text/calendar"])
        #expect(structure.attachments.first?.cid == "logo@x")
        #expect(structure.attachments[1].name == "bill.pdf")

        let (body, parts) = BodyStructure.render(raw: Data(Self.raw.utf8), blobId: "m1")
        #expect(body.text == "Café at noon, a long line that wraps with a soft break.")
        #expect(body.html == #"<p>Café <img src="cid:logo@x"></p>"#)
        #expect(parts.map(\.blobId) == ["m1.1.2", "m1.2", "m1.3"])
        #expect(parts.map(\.size) == [8, 8, 15])
    }

    @Test func mapsWholeMessagesFromTheirOwnHeaders() throws {
        let m = try message(#"{"id": "w1", "threadId": "t1", "labelIds": ["INBOX", "UNREAD"], "snippet": "Café", "internalDate": "1700000000000", "sizeEstimate": 900}"#)
        let mime = MIMEPart.parse(Data(Self.raw.utf8))
        let incoming = try #require(GmailAccountSync.incoming(m, raw: mime, mailboxLabels: ["INBOX"]))
        #expect(incoming.subject == "Invite" && incoming.addresses.first?.email == "ann@x.com" && incoming.addresses.first?.name == "Ann")
        #expect(incoming.mailboxRemoteIds == ["INBOX"] && incoming.keywords.isEmpty)
        #expect(incoming.hasAttachment)  // the PDF and the invite (the HTML's picture alone wouldn't count)
        let plain = MIMEPart.parse(Data("Subject: Hi\r\nFrom: b@y.com\r\n\r\nJust text".utf8))
        #expect(GmailAccountSync.incoming(m, raw: plain, mailboxLabels: ["INBOX"])?.hasAttachment == false)
    }

    @Test func attachmentSizesComeWithoutDecoding() {
        for length in [0, 1, 2, 3, 4, 57, 58, 59, 1000, 54_321] {
            let bytes = Data((0..<length).map { _ in UInt8.random(in: 0...255) })
            let encoded = bytes.base64EncodedString(options: .lineLength76Characters)  // CRLF every 76, padded
            let raw = "Content-Type: multipart/mixed; boundary=b\r\n\r\n--b\r\nContent-Type: text/plain\r\n\r\nHi\r\n"
                + "--b\r\nContent-Type: application/octet-stream\r\nContent-Transfer-Encoding: base64\r\n\r\n\(encoded)\r\n--b--\r\n"
            let part = MIMEPart.parse(Data(raw.utf8)).children[1]
            #expect(part.contentSize == bytes.count && part.content == bytes, "\(length) bytes")
        }
    }

    @Test func parsesAwkwardMIME() throws {
        // LF line ends, a header folded over two lines, no closing delimiter.
        let lf = "Content-Type: multipart/mixed;\n boundary=b\n\n--b\nContent-Type: text/plain\n\nfirst\n--b\nContent-Type: message/rfc822\n\nSubject: inner\n\nhello\n"
        let message = MIMEPart.parse(Data(lf.utf8))
        #expect(message.children.count == 2)
        #expect(String(decoding: message.children[0].content, as: UTF8.self) == "first")
        #expect(BodyStructure(message).attachments.first?.name == "message.eml")
        #expect(message.find("2")?.type == "message/rfc822")
        // A single-part message without headers' Content-Type is text/plain.
        let plain = MIMEPart.parse(Data("Subject: x\r\n\r\nJust text".utf8))
        #expect(plain.type == "text/plain" && String(decoding: plain.content, as: UTF8.self) == "Just text")
        #expect(MailHeaders.quotedPrintable(bytes: Array("a=3Db=\r\nc= \r\nd".utf8)) == Data("a=bcd".utf8))
    }

    @Test func searchesForTheIMAPFlags() {
        #expect(GmailAccountSync.searchKey("\\Answered") == "ANSWERED")
        #expect(GmailAccountSync.searchKey("$Forwarded") == "KEYWORD $Forwarded")
        #expect(GmailAccountSync.anyOf(["a"]) == "a")
        #expect(GmailAccountSync.anyOf(["a", "b", "c"]) == "OR a OR b c")
        #expect(GmailAccountSync.imapKeywords == ["$answered": "\\Answered", "$forwarded": "$Forwarded"])
    }

    @Test func labelChangesApplyAsTheirLabelsWouldMap() throws {
        let boxes: Set<String> = ["INBOX", "SENT", "DRAFT", "TRASH", "SPAM", "ARCHIVE", "Label_7"]
        typealias Change = GmailAccountSync.LabelChange
        func apply(_ changes: [Change], _ keywords: Set<String>, _ mailboxes: Set<String>, archiveLabel: String? = nil)
            -> GmailAccountSync.Marks?
        {
            GmailAccountSync.applying(changes, to: (keywords, mailboxes), mailboxLabels: boxes, archiveLabel: archiveLabel)
        }
        // Read, flagged; unrelated labels change nothing.
        let read = try #require(apply([Change(added: false, labels: ["UNREAD"]), Change(added: true, labels: ["STARRED", "IMPORTANT"])],
                                      [], ["INBOX"]))
        #expect(read.keywords == ["$seen", "$flagged"] && read.mailboxes == ["INBOX"])
        #expect(apply([Change(added: true, labels: ["UNREAD"])], ["$seen", "$answered"], ["INBOX"])?.keywords == ["$answered"])
        // Archived in Gmail (Inbox taken off): Archive. Back to the Inbox: out of Archive.
        #expect(apply([Change(added: false, labels: ["INBOX"])], [], ["INBOX"])?.mailboxes == ["ARCHIVE"])
        #expect(apply([Change(added: true, labels: ["INBOX"])], [], ["ARCHIVE"])?.mailboxes == ["INBOX"])
        #expect(apply([Change(added: true, labels: ["Label_7"])], [], ["INBOX"])?.mailboxes == ["INBOX", "Label_7"])
        // With an archive label: it puts a message in Archive, alongside its other mailboxes.
        #expect(apply([Change(added: true, labels: ["Label_9"])], [], ["INBOX"], archiveLabel: "Label_9")?.mailboxes
            == ["INBOX", "ARCHIVE"])
        #expect(apply([Change(added: false, labels: ["INBOX"])], [], ["INBOX", "ARCHIVE"], archiveLabel: "Label_9")?.mailboxes
            == ["ARCHIVE"])
        // In Archive and given a mailbox: whether it also has the archive label, only Gmail knows.
        #expect(apply([Change(added: true, labels: ["INBOX"])], [], ["ARCHIVE"], archiveLabel: "Label_9") == nil)
    }

    @Test func messagesAreFoundOverIMAPByTheirIds() {
        // Gmail's ids in decimal (X-GM-MSGID), a few to a search; one that isn't Gmail's is left out.
        #expect(GmailAccountSync.idSearches(["1f", "draft", "a", "ff"], each: 2) == ["OR X-GM-MSGID 31 X-GM-MSGID 10", "X-GM-MSGID 255"])
        #expect(GmailAccountSync.idSearches([]).isEmpty)
    }

    @Test func previewsAreTheTextsFirstWordsOnOneLine() {
        #expect(GmailAccountSync.preview("  Hello,\n\n  world\t again ") == "Hello, world again")
        let long = String(repeating: "word ", count: 100)
        #expect(GmailAccountSync.preview(long) == String(long.prefix(200)))
        // A space and a zero-width character after it are one character, as they show.
        let zeroWidth = "a\n\u{200C} " + String(repeating: "b", count: 300)
        #expect(GmailAccountSync.preview(zeroWidth) == "a \u{200C} " + String(repeating: "b", count: 197))
        #expect(GmailAccountSync.preview(zeroWidth).count == 200)
    }

    /// An actor using `concurrently` as the Gmail sync does: what's done is handled as it comes.
    actor Handled {
        var order: [Int] = []
        func run(_ delays: [Int]) async throws {
            try await concurrently(Array(delays.indices), limit: 4, { index in
                try await Task.sleep(for: .milliseconds(delays[index]))
                return index * 10
            }) { index, output in
                #expect(output == index * 10)
                order.append(index)  // on the actor, without awaiting it
            }
        }
    }

    @Test func concurrentWorkIsHandledAsItFinishes() async throws {
        let handled = Handled()
        try await handled.run([450, 0, 300, 150])
        #expect(await handled.order == [1, 3, 2, 0])  // fastest first, each once
        let none = Handled()
        try await none.run([])
        #expect(await none.order.isEmpty)
    }
}
