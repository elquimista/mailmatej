import Foundation
import Testing

@testable import MailSync

@Suite struct MarkdownMailTests {
    @Test func linesStayLinesAndTextIsEscaped() {
        let html = MarkdownMail.html("Hi Ana,\nsee <this> & that.\n\nBest")
        #expect(html.contains("Hi Ana,<br>\nsee &lt;this&gt; &amp; that.</p>"))
        #expect(html.contains(">Best</p>"))
    }

    @Test func anHTMLSignatureTakesTheSignaturesPlace() {
        let text = "Hi **Bob**\n\nBest,\nAlice\n\nOn 2 Nov, Bob wrote:\n\n> Yes"
        let signature = (text as NSString).range(of: "Best,\nAlice\n")
        let html = MarkdownMail.html(text, signature: signature, signatureHTML: "<div class=\"sig\">Alice</div>")
        #expect(html.contains("<strong>Bob</strong>"))
        #expect(html.contains("<div class=\"sig\">Alice</div>"))
        #expect(!html.contains("Best,") && !html.contains("MMJSIGNATURE"))
        #expect(html.range(of: "sig")!.lowerBound < html.range(of: "Bob wrote")!.lowerBound)
        let plain = MarkdownMail.plainHTML("Hi <b>\n\nBest,\nAlice\n", signature: (("Hi <b>\n\nBest,\nAlice\n") as NSString).range(of: "Best,\nAlice\n"), signatureHTML: "<i>A</i>")
        #expect(plain.contains("Hi &lt;b&gt;<br>\n<br>\n<i>A</i>"))
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

    @Test func embeddedPicturesInTheTextPart() {
        #expect(MarkdownMail.plainText("Look:\n\n![](cid:A1@example.com \"This-is-fine.jpeg\")\n\nBye")
            == "Look:\n\n[ \"This-is-fine.jpeg\" ]\n\nBye")
        #expect(MarkdownMail.plainText("![dog](cid:B2@example.com)") == "[ \"dog\" ]")
        #expect(MarkdownMail.plainText("![x](https://example.com/x.png)") == "![x](https://example.com/x.png)")  // not embedded
        #expect(Compose.quote("Hi\n![](cid:C3@example.com \"a.png\")") == "> Hi\n> [ \"a.png\" ]")
    }

    @Test func likeMailMates() {
        // MailMate 3's HTML for a reply with a quote: its skeleton, plain punctuation and quote style.
        let html = MarkdownMail.html("Please check.\n\n> [ \"a.jpeg\" ] -- ok")
        #expect(html.contains("<body style=\"font-family: sans-serif;\">\n<div class=\"markdown\" style=\"white-space: normal;\">"))
        #expect(html.contains("<p dir=\"auto\">Please check.</p>"))
        #expect(html.contains("<blockquote style=\"margin: 0 0 5px; padding-left: 5px; border-left: 2px solid #777777; color: #777777;\">"))
        #expect(html.contains("[ &quot;a.jpeg&quot; ] -- ok"))
    }
}
