import Foundation
import Testing
@testable import GmailKit

struct GmailSMTPTests {
    @Test func stuffsDotsAndEndsLinesInCRLF() {
        let message = Data("Subject: Hi\r\n\r\n.leading dot\n..two\nlast".utf8)
        let sent = String(decoding: GmailSMTP.dataLines(message), as: UTF8.self)
        #expect(sent == "Subject: Hi\r\n\r\n..leading dot\r\n...two\r\nlast\r\n.\r\n")
        // Already CRLF and ending in one: nothing doubled.
        #expect(String(decoding: GmailSMTP.dataLines(Data("a\r\nb\r\n".utf8)), as: UTF8.self) == "a\r\nb\r\n.\r\n")
        // 8-bit bytes pass as they are.
        let utf8 = Data("Subject: café\r\n\r\nñ\r\n".utf8)
        #expect(GmailSMTP.dataLines(utf8) == utf8 + Data(".\r\n".utf8))
    }

    @Test func readsReplyLines() {
        #expect(SMTPConnection.parse("250-SIZE 35882577")! == (250, "SIZE 35882577", false))
        #expect(SMTPConnection.parse("250 SMTPUTF8")! == (250, "SMTPUTF8", true))
        #expect(SMTPConnection.parse("334 eyJzdGF0dXMiOiI0MDEifQ==")! == (334, "eyJzdGF0dXMiOiI0MDEifQ==", true))
        #expect(SMTPConnection.parse("220")! == (220, "", true))
        #expect(SMTPConnection.parse("hello") == nil)
    }
}
