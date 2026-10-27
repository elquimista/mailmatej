import Foundation
import JMAPKit
import Testing

@testable import MailSync

@Suite struct OutgoingMIMETests {
    private func outgoing() -> OutgoingMessage {
        var message = OutgoingMessage(
            identityId: "me@gmail.com", from: EmailAddress(name: "José Álvarez", email: "me@gmail.com"),
            to: [EmailAddress(name: "Doe, Jane", email: "jane@x.com"), EmailAddress(name: nil, email: "bob@y.org")],
            cc: [EmailAddress(name: "Zoë", email: "zoe@z.net")], bcc: [EmailAddress(name: nil, email: "hidden@h.com")],
            subject: "Café plans — a rather long subject line that has to be folded somewhere along the way",
            text: "Hello Jane,\n\nThe café opens at 9. A very long line follows: " + String(repeating: "word ", count: 30)
                + "\nEnds with a space \n",
            inReplyTo: ["a@x.com"], references: ["r1@x.com", "a@x.com"])
        message.html = "<p>Hello <img src=\"cid:pic1\"></p>"
        message.draftFormat = "markdown"
        return message
    }

    private let picture = OutgoingMIME.Attachment(name: "dot.png", type: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]), cid: "pic1")
    private let file = OutgoingMIME.Attachment(name: "Résumé (final).pdf", type: "application/pdf", data: Data((0..<300).map { UInt8($0 % 256) }))

    @Test func readsBackAsWritten() throws {
        let raw = OutgoingMIME.message(outgoing(), attachments: [picture, file], bcc: true, asDraft: true)
        let message = MIMEPart.parse(raw)
        #expect(MailHeaders.decodeWords(message.header("Subject") ?? "") == outgoing().subject)
        let from = MailHeaders.addresses(MailHeaders.decodeWords(message.header("From") ?? "")).addresses
        #expect(from == [MailHeaders.Address(name: "José Álvarez", email: "me@gmail.com")])
        let to = MailHeaders.addresses(message.header("To") ?? "").addresses
        #expect(to == [MailHeaders.Address(name: "Doe, Jane", email: "jane@x.com"), MailHeaders.Address(name: nil, email: "bob@y.org")])
        #expect(message.header("Bcc") == "hidden@h.com")
        #expect(MailHeaders.messageIds(message.header("References")) == ["r1@x.com", "a@x.com"])
        #expect(MailHeaders.messageIds(message.header("In-Reply-To")) == ["a@x.com"])
        #expect(message.header("X-MailMateJ-Format") == "markdown")
        #expect(MailHeaders.messageIds(message.header("Message-ID")).first?.hasSuffix("@gmail.com") == true)
        #expect(MailHeaders.date(message.header("Date")) != nil)

        // mixed [ related [ alternative [text, html], picture ], file ]
        #expect(message.type == "multipart/mixed")
        let related = try #require(message.find("1"))
        #expect(related.type == "multipart/related")
        #expect(message.find("1.1")?.type == "multipart/alternative")
        let text = try #require(message.find("1.1.1"))
        #expect(text.type == "text/plain")
        #expect(MailHeaders.text(text.content, charset: "utf-8") == outgoing().text.replacingOccurrences(of: "\n", with: "\r\n"))
        #expect(message.find("1.1.2")?.type == "text/html")
        let shown = try #require(message.find("1.2"))
        #expect(shown.header("Content-ID") == "<pic1>" && shown.content == picture.data)
        #expect(MailHeaders.value(of: shown.header("Content-Disposition")) == "inline")
        let attached = try #require(message.find("2"))
        #expect(attached.content == file.data)
        #expect(MailHeaders.parameter("filename", in: attached.header("Content-Disposition")) == "Résumé (final).pdf")
        #expect(MailHeaders.parameter("name", in: attached.header("Content-Type")) == "Résumé (final).pdf")
    }

    @Test func keepsLinesShort() {
        let raw = OutgoingMIME.message(outgoing(), attachments: [picture, file], bcc: true)
        let lines = String(decoding: raw, as: UTF8.self).components(separatedBy: "\r\n")
        #expect(lines.allSatisfy { $0.utf8.count <= 78 })
        #expect(!String(decoding: raw, as: UTF8.self).contains("\n\n"))  // CRLF everywhere, no bare LF
        #expect(raw.allSatisfy { $0 < 128 })  // all of it ASCII
    }

    @Test func leavesOutBccAndDraftHeaderWhenSending() {
        let raw = OutgoingMIME.message(outgoing(), attachments: [], bcc: false)
        let message = MIMEPart.parse(raw)
        #expect(message.header("Bcc") == nil && message.header("X-MailMateJ-Format") == nil)
    }

    @Test func plainTextAloneIsOnePart() {
        var plain = outgoing()
        plain.html = nil
        plain.text = "Short and simple.\nTwo lines."
        let message = MIMEPart.parse(OutgoingMIME.message(plain, attachments: [], bcc: false))
        #expect(message.type == "text/plain" && message.children.isEmpty)
        #expect(message.header("Content-Transfer-Encoding") == "7bit")
        #expect(String(decoding: message.content, as: UTF8.self) == "Short and simple.\r\nTwo lines.")
    }

    @Test func encodesNamesAsTheyNeed() {
        #expect(OutgoingMIME.phrase("Jane Doe") == "Jane Doe")
        #expect(OutgoingMIME.phrase("Doe, Jane") == "\"Doe, Jane\"")
        #expect(OutgoingMIME.phrase("Say \"hi\"") == "\"Say \\\"hi\\\"\"")
        #expect(MailHeaders.decodeWords(OutgoingMIME.phrase("Zoë")) == "Zoë")
        // Long non-ASCII text: several words, none over 75, characters kept whole.
        let long = String(repeating: "日本語のテキスト", count: 8)
        let words = OutgoingMIME.encodedWords(long)
        #expect(words.count > 1 && words.allSatisfy { $0.count <= 75 })
        #expect(MailHeaders.decodeWords(words.joined(separator: " ")) == long)
    }
}
