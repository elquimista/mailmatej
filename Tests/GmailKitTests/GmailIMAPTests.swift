import Foundation
import Testing
@testable import GmailKit

struct GmailIMAPTests {
    private func text(_ s: String) -> IMAPResponseParser.Segment { .text(Array(s.utf8)) }

    @Test func parsesAFetchWithALiteral() throws {
        let body = Data("Subject: Hi\r\n\r\nHello".utf8)
        let response = IMAPResponseParser.parse([
            text(#"* 12 FETCH (X-GM-THRID 1612345678901234567 X-GM-MSGID 1612345678901234568 X-GM-LABELS ("\\Inbox" "\\Important" Work "My &AOk-t&AOk-") UID 99 FLAGS (\Seen \Flagged) INTERNALDATE "17-Jul-1996 02:44:25 -0700" RFC822.SIZE 22 BODY[] {22}"#),
            .literal(body),
            text(")"),
        ])
        #expect(response.first?.atom == "*")
        let fields = try #require(GmailIMAP.fetchFields(Array(response.dropFirst())))
        #expect(fields["UID"]?.atom == "99")
        #expect(fields["BODY[]"]?.data == body)
        guard case .list(let labels)? = fields["X-GM-LABELS"] else { Issue.record("no labels"); return }
        #expect(labels.compactMap(\.text).map(GmailIMAP.decodeModifiedUTF7) == ["\\Inbox", "\\Important", "Work", "My été"])
        guard case .list(let flags)? = fields["FLAGS"] else { Issue.record("no flags"); return }
        #expect(flags.compactMap(\.atom) == ["\\Seen", "\\Flagged"])
        #expect(GmailIMAP.internalDate(fields["INTERNALDATE"]!.text!) == Date(timeIntervalSince1970: 837_596_665))
        // The API's id is X-GM-MSGID in hex.
        let hex = String(UInt64(fields["X-GM-MSGID"]!.atom!)!, radix: 16)
        #expect(UInt64(hex, radix: 16) == 1_612_345_678_901_234_568)
    }

    @Test func parsesListAndStatusLines() {
        let list = IMAPResponseParser.parse([text(#"* LIST (\HasNoChildren \All) "/" "[Gmail]/All Mail""#)])
        #expect(list.count == 5 && list[4].text == "[Gmail]/All Mail")
        let ok = IMAPResponseParser.parse([text("m3 OK [READ-ONLY] EXAMINE completed")])
        #expect(ok.first?.atom == "m3" && ok[1].atom == "OK" && ok[2].atom == "[READ-ONLY]")
    }

    @Test func readsCondstoreCodesAndSearches() {
        let responses = [
            #"* FLAGS (\Answered \Flagged \Draft \Deleted \Seen $Forwarded $NotPhishing $Phishing)"#,
            #"* OK [PERMANENTFLAGS (\Answered \Flagged \Draft \Deleted \Seen $Forwarded \*)] Flags permitted."#,
            "* OK [UIDVALIDITY 11] UIDs valid.",
            "* 91234 EXISTS",
            "* OK [UIDNEXT 99112] Predicted next UID.",
            "* OK [HIGHESTMODSEQ 4182733] Highest",
        ].map { Array(IMAPResponseParser.parse([text($0)]).dropFirst()) }
        let opened = GmailIMAP.opened(responses)
        #expect(opened.uidValidity == 11 && opened.highestModSeq == 4_182_733)
        let search = [Array(IMAPResponseParser.parse([text("* SEARCH 4 9 12 (MODSEQ 917)")]).dropFirst())]
        #expect(GmailIMAP.searchResults(search) == [4, 9, 12])
        #expect(GmailIMAP.searchResults([Array(IMAPResponseParser.parse([text("* SEARCH")]).dropFirst())]).isEmpty)
        // CHANGEDSINCE's FETCH has MODSEQ beside the items asked for.
        let fetch = IMAPResponseParser.parse([text(#"* 5 FETCH (UID 12 X-GM-MSGID 1612345678901234568 FLAGS (\Answered \Seen $Forwarded) MODSEQ (4182730))"#)])
        let fields = GmailIMAP.fetchFields(Array(fetch.dropFirst()))
        guard case .list(let flags)? = fields?["FLAGS"] else { Issue.record("no flags"); return }
        #expect(flags.compactMap(\.atom) == ["\\Answered", "\\Seen", "$Forwarded"])
    }

    @Test func readsInternalDates() {
        #expect(GmailIMAP.internalDate("17-Jul-1996 02:44:25 -0700") == Date(timeIntervalSince1970: 837_596_665))
        #expect(GmailIMAP.internalDate(" 1-Jan-2025 00:00:00 +0000") == Date(timeIntervalSince1970: 1_735_689_600))
        #expect(GmailIMAP.internalDate("not a date") == nil)
    }

    @Test func writesUIDSetsAsRanges() {
        #expect(GmailIMAP.uidSet([5, 1, 2, 3, 9, 12, 13, 14, 20]) == "1:3,5,9,12:14,20")
        #expect(GmailIMAP.uidSet([7]) == "7")
        #expect(GmailIMAP.quoted(#"a "b" \c"#) == #""a \"b\" \\c""#)
    }
}
