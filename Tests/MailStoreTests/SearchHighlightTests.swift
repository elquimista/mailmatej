import Foundation
import Testing

@testable import MailStore

/// What a search marks in the message shown, as MailMate highlights it.
@Suite struct SearchHighlightTests {
    @Test func wordsAndQuotedPhrases() {
        #expect(SearchHighlight.terms("  morgan  chase ").map(\.text) == ["morgan", "chase"])
        #expect(SearchHighlight.terms("\"affiliates of  JPMorgan Chase\"").map(\.text) == ["affiliates of JPMorgan Chase"])
        #expect(SearchHighlight.terms("sale \"J.P. Morgan\" Sale").map(\.text) == ["sale", "J.P. Morgan"])
        #expect(SearchHighlight.terms("\"unclosed phrase").map(\.text) == ["unclosed phrase"])
        #expect(SearchHighlight.terms("   ").isEmpty)
    }

    @Test func foundIgnoringCaseAndAccentsWhereAWordStarts() {
        func marked(_ search: String, in text: String) -> [String] {
            SearchHighlight.ranges(of: SearchHighlight.terms(search), in: text).map { (text as NSString).substring(with: $0) }
        }
        #expect(marked("\"j.p. morgan workplace solutions\"", in: "Sale request: J.P. Morgan Workplace Solutions") == ["J.P. Morgan Workplace Solutions"])
        #expect(marked("morg", in: "Morgan, Stormorg, morgen") == ["Morg", "morg"])
        #expect(marked("cafe", in: "Le Café") == ["Café"])
        // Words side by side read as one mark; apart, each its own.
        #expect(marked("J.P. Morgan Workplace Solutions", in: "Sale request update: J.P. Morgan Workplace Solutions")
            == ["J.P. Morgan Workplace Solutions"])
        #expect(marked("morgan solutions", in: "J.P. Morgan Workplace Solutions") == ["Morgan", "Solutions"])
        #expect(marked("sale update", in: "Sale, update") == ["Sale", "update"])  // a comma parts them
        // Find counts each match, side by side too, anywhere in a word.
        let find = SearchHighlight.ranges(of: [SearchHighlight("sen", wordStart: false)], in: "Jensen sen sen", joiningSpaced: false)
        #expect(find.map(\.location) == [3, 7, 11])
    }

    @Test func aCustomSearchMarksWhatItsContainsRowsLookFor() {
        let condition = SmartCondition.compound(.all, [
            .rule(.headersOrUnquoted, .contains, "\"Workplace Solutions\" sale"),
            .rule(.subject, .contains, "organ"),
            .rule(.subject, .doesNotContain, "spam"),
            .rule(.fromAddress, .contains, "equityadmin", enabled: false),
        ])
        #expect(condition.highlights == [
            SearchHighlight("Workplace Solutions", group: 1), SearchHighlight("sale", group: 1),
            SearchHighlight("organ", wordStart: false, group: 2),
        ])
        let subject = "J.P. Morgan" as NSString
        let ranges = SearchHighlight.ranges(of: condition.highlights, in: subject as String)
        #expect(ranges.map { subject.substring(with: $0) } == ["organ"])  // a Subject row: anywhere
    }

    /// Two rows side by side stay two marks; one row's words, one.
    @Test func eachRowIsItsOwnMark() {
        let condition = SmartCondition.compound(.all, [
            .rule(.headersOrUnquoted, .contains, "J.P. Morgan"), .rule(.headersOrUnquoted, .contains, "Workplace Solutions"),
        ])
        let subject = "Sale request update: J.P. Morgan Workplace Solutions" as NSString
        let ranges = SearchHighlight.ranges(of: condition.highlights, in: subject as String)
        #expect(ranges.map { subject.substring(with: $0) } == ["J.P. Morgan", "Workplace Solutions"])

        // The same words in two rows: still one mark.
        let twice = SmartCondition.compound(.all, [
            .rule(.headersOrUnquoted, .contains, "J.P. Morgan Workplace Solutions"),
            .rule(.headersOrUnquoted, .contains, "J.P. Morgan Workplace Solutions"),
        ])
        let same = SearchHighlight.ranges(of: twice.highlights, in: subject as String)
        #expect(same.map { subject.substring(with: $0) } == ["J.P. Morgan Workplace Solutions"])
    }
}
