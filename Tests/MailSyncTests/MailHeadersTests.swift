import Foundation
import Testing

@testable import MailSync

@Suite struct MailHeadersTests {
    @Test func decodesEncodedWords() {
        #expect(MailHeaders.decodeWords("=?UTF-8?B?0J/RgNC40LLQtdGC?=") == "Привет")
        #expect(MailHeaders.decodeWords("=?ISO-8859-1?Q?Caf=E9_cr=E8me?=") == "Café crème")
        // Whitespace between encoded words goes; around plain text it stays.
        #expect(MailHeaders.decodeWords("=?UTF-8?Q?a?= =?UTF-8?Q?b?= c") == "ab c")
        #expect(MailHeaders.decodeWords("Plain subject") == "Plain subject")
    }

    @Test func parsesAddressLists() {
        let parsed = MailHeaders.addresses(#""Doe, Jane" <jane@x.com>, bob@y.org, =?UTF-8?Q?Jos=C3=A9?= <jose@z.es> (work)"#)
        #expect(parsed.addresses == [
            .init(name: "Doe, Jane", email: "jane@x.com"), .init(name: nil, email: "bob@y.org"), .init(name: "José", email: "jose@z.es"),
        ])
        let groups = MailHeaders.addresses("undisclosed-recipients:;")
        #expect(groups.addresses.isEmpty && groups.emptyGroups == ["undisclosed-recipients"])
        let team = MailHeaders.addresses("Team: a@x.com, b@x.com;, c@y.com")
        #expect(team.addresses.map(\.email) == ["a@x.com", "b@x.com", "c@y.com"] && team.emptyGroups.isEmpty)
    }

    @Test func readsMessageIdsAndDates() {
        #expect(MailHeaders.messageIds("<a@x>\r\n <b@y>") == ["a@x", "b@y"])
        #expect(MailHeaders.messageIds(nil).isEmpty)
        let date = MailHeaders.date("Tue, 1 Jul 2003 10:52:37 +0200")
        #expect(date == Date(timeIntervalSince1970: 1_057_049_557))
        #expect(MailHeaders.date("1 Jul 2003 10:52 +0200 (CEST)") == Date(timeIntervalSince1970: 1_057_049_520))
    }

    @Test func readsParameters() {
        #expect(MailHeaders.parameter("charset", in: #"text/plain; charset="ISO-8859-1"; format=flowed"#) == "ISO-8859-1")
        #expect(MailHeaders.value(of: "Text/HTML; charset=utf-8") == "text/html")
        #expect(MailHeaders.parameter("filename", in: "attachment; filename*=UTF-8''na%C3%AFve.pdf") == "naïve.pdf")
        #expect(MailHeaders.parameter("name", in: "application/pdf; name*0=\"long\"; name*1=\"name.pdf\"") == "longname.pdf")
    }

    @Test func decodesSnippetEntities() {
        #expect(MailHeaders.decodeEntities("Don&#39;t &amp; won&#x27;t &lt;3") == "Don't & won't <3")
    }
}
