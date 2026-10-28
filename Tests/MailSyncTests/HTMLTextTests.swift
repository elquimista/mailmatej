import Foundation
import Testing

@testable import MailSync

@Suite struct HTMLTextTests {
    /// A seeded generator, so a failure comes back the same.
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Pieces of HTML that matter to the expressions, and some that don't.
    static let pieces = [
        "<", ">", "/", "</", "<!--", "-->", "style", "STYLE", "Style", "script", "head", "header", "title", "br", "BR", "p", "pre",
        "div", "tr", "li", "h", "h1", "H2", "1", "x", "_", "=", "\"", "'", " ", "  ", "\n", "\t", "\r", "\r\n", "\u{0C}", "\u{0B}",
        "&", ";", "#", "&nbsp;", "&lt;", "&gt;", "&quot;", "&#39;", "&amp;", "&amp", "nbsp", "lt;", "amp;", "é", "Ж", "中", "😀",
        "\u{A0}", "\u{85}", "\u{1680}", "\u{2003}", "\u{2028}", "\u{202F}", "\u{3000}", "\u{200B}", "\u{FEFF}", "\u{301}",
        "\u{FE0F}", "\u{200C}", "\u{200D}", "\u{1F3FB}", "\u{F870}", "\u{903}", "\u{17F}", "\u{FB06}", "\u{37E}", "\u{661}",
    ]

    @Test func readsTextAsTheExpressionsDo() throws {
        let cases = [
            "", "plain", "<p>a</p><p>b</p>", "<STYLE>x</style>y", "<style>x</STYLE >y", "<style>never closed", "<style>a</style><style>b",
            "<script>if (a < b) {}</script>c", "<head><title>T</title></head>body", "<header>kept</header>", "<br/>x<BR >y<br",
            "</h1>a</h12>b</h>c", "<>a<<b>c", "a<b", "x > y", "&amp;lt;b&amp;gt;", "&nbsp;&nbsp;a&nbsp;\n&nbsp;b", "a&#39;s &quot;q&quot;",
            "a \t\r\u{0C} b", " \n\u{A0}\n x \u{3000}\n", "\u{2028}a\u{85}", "<p>Ж</p>&nbsp;中文 😀", "<title>a\nb</title>c",
            "<!--[if mso]><table><tr><td>x</td></tr></table><![endif]-->y",
            // An entity followed by what extends its semicolon stays (Foundation's search doesn't find it).
            "a&nbsp;\u{200C}&nbsp;\u{200C}b", "&lt;\u{301}", "&gt;\u{1F3FB}", "&nbsp;\u{200B}", "&lt;\u{200D}", "&quot;\u{903}", "&amp;\u{F870}", "&#39;s",
        ]
        for html in cases {
            #expect(try HTMLText.scanned(html) == HTMLText.byExpressions(html), "\(html.debugDescription)")
        }

        var random = SplitMix(state: 42)
        var scanned = 0
        let count = 3000
        for _ in 0..<count {
            let html = (0..<Int.random(in: 0...30, using: &random)).map { _ in Self.pieces.randomElement(using: &random)! }.joined()
            guard let fast = try? HTMLText.scanned(html) else { continue }  // left to the expressions
            scanned += 1
            #expect(fast == HTMLText.byExpressions(html), "\(html.debugDescription)")
        }
        #expect(scanned > count / 2)
    }

    @Test func leavesWhatItCantBeSureOfToTheExpressions() {
        for html in ["<\u{17F}tyle>a</style>b", "<style\u{200B}>a</style>b", "</h\u{661}>a", "&lt\u{37E}", "&#39;\u{903}"] {
            #expect(throws: HTMLText.Unsure.self) { try HTMLText.scanned(html) }
            #expect(HTMLText.plainText(html) == HTMLText.byExpressions(html))
        }
    }
}
