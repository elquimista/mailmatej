import Testing

@testable import MailSync

@Suite struct MarkdownMailTests {
    @Test func linesStayLinesAndTextIsEscaped() {
        let html = MarkdownMail.html("Hi Ana,\nsee <this> & that.\n\nBest")
        #expect(html.contains("Hi Ana,<br>\nsee &lt;this&gt; &amp; that.</p>"))
        #expect(html.contains(">Best</p>"))
    }

    @Test func markdownBecomesHTML() {
        let html = MarkdownMail.html("**bold** _it_ `x<y`\n\n- one\n- two\n\n> quoted\n\n[link](https://example.com?a=1&b=2)")
        #expect(html.contains("<strong>bold</strong> <em>it</em>"))
        #expect(html.contains(">x&lt;y</code>"))
        #expect(html.contains("<li>one</li>"))
        #expect(html.contains("<blockquote") && html.contains("quoted"))
        #expect(html.contains("href=\"https://example.com?a=1&amp;b=2\""))
    }

    @Test func embeddedImagesKeepTheirContentIDs() {
        let text = "Look:\n\n![](cid:7F84BEEB-2704@example.com \"IMG-1.jpg\")"
        #expect(MarkdownMail.imageContentIDs(text) == ["7F84BEEB-2704@example.com"])
        #expect(MarkdownMail.html(text).contains("<img src=\"cid:7F84BEEB-2704@example.com\" alt=\"\" title=\"IMG-1.jpg\""))
    }
}
