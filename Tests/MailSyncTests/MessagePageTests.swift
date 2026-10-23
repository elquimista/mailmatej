import Foundation
import Testing

@testable import MailSync

@Suite struct MessagePageTests {
    @Test func pageHoldsOnlyTheContentWithScriptsOff() {
        let page = MessagePage.html(content: "<p>x</p>", plain: false, remote: false)
        #expect(page.contains("<mmj-content><p>x</p></mmj-content><mmj-end></mmj-end>"))
        #expect(!page.contains("mmj-chrome"))
        #expect(page.contains("script-src 'none'"))
        #expect(!page.contains("https:;"))  // no remote sources unless allowed
    }

    @Test func barOffersActionsOnlyWhenUseful() {
        let blocked = MessagePage.Bar(remote: 5, strict: 2, loaded: false, canAlwaysLoad: true, allowedBy: [])
        #expect(blocked.text == "Blocked 5 remote resources · 2 tracker or insecure resources always blocked")
        #expect(blocked.actions.map(\.action) == [.load, .alwaysLoadMenu])

        let onlyStrict = MessagePage.Bar(remote: 1, strict: 1, loaded: false, canAlwaysLoad: true, allowedBy: [])
        #expect(onlyStrict.actions.isEmpty)

        let loaded = MessagePage.Bar(remote: 3, strict: 0, loaded: true, canAlwaysLoad: true, allowedBy: ["@x.com"])
        #expect(loaded.text == "Loaded 3 remote resources")
        #expect(loaded.actions.map(\.action) == [.stopAlwaysLoading])
    }

    @Test func plainTextQuotesBecomeNestedBlocksWithoutMarkers() {
        let html = MessagePage.plainHTML("Yes!\n\nOn 19 Oct, A wrote:\n\n> This <is>\n>> older\n> back\nAfter")
        #expect(html == "<mmj-line>Yes!</mmj-line><mmj-line><br></mmj-line><mmj-line>On 19 Oct, A wrote:</mmj-line>"
            + "<mmj-line><br></mmj-line><mmj-quote><mmj-line>This &lt;is&gt;</mmj-line>"
            + "<mmj-quote><mmj-line>older</mmj-line></mmj-quote><mmj-line>back</mmj-line></mmj-quote>"
            + "<mmj-line>After</mmj-line>")
    }

    @Test func onlyHTMLWithoutColorsFollowsDarkMode() {
        #expect(MessagePage.hasNoColors("<p>Hi Ellie,</p><p>&nbsp;</p>"))
        #expect(!MessagePage.hasNoColors(##"<p style="color: #333">Hi</p>"##))
        #expect(!MessagePage.hasNoColors(##"<td bgcolor="#fff">Hi</td>"##))
        #expect(!MessagePage.hasNoColors("<style>body { background:#fff }</style>"))
        #expect(!MessagePage.hasNoColors(#"<font color=red>Hi</font>"#))
        // Any colour value counts, as in MailMate: Gmail's quote bar keeps a reply on white.
        #expect(!MessagePage.hasNoColors(#"<blockquote style="margin:0px;border-left:1px solid rgb(204,204,204);padding-left:1ex">x</blockquote>"#))
        #expect(!MessagePage.hasNoColors(##"<div style="border-top: 1px solid #ccc">x</div>"##))
        #expect(!MessagePage.hasNoColors(#"<hr style="border: 0; border-top: 1px dotted grey">"#))
        #expect(!MessagePage.hasNoColors(#"<p style="text-shadow: 0 1px 1px hsla(0,0%,0%,.2)">x</p>"#))
        // ...but not markup that only looks similar: a bare tracking pixel, links with #anchors, border widths.
        #expect(MessagePage.hasNoColors(#"<p>Hello Ellie,</p><img src="https://x.example/open?m=1" border="0" width="1" height="1">"#))
        #expect(MessagePage.hasNoColors(##"<a href="https://x.example/page#abc123">link</a> <table border="1"><td>x</td></table>"##))
        #expect(MessagePage.hasNoColors(#"<div style="border: 1px solid; margin: 0">x</div>"#))
        // Pictures keep HTML on white too; a tracking pixel doesn't.
        #expect(MessagePage.hasPictures(#"<p>Hi</p><img src="cid:abc@example.com" alt="" title="x.jpg" style="max-width: 100%;">"#))
        #expect(MessagePage.hasPictures(#"<img src="https://x.example/logo.png" width="120">"#))
        #expect(!MessagePage.hasPictures(#"<p>Hello Ellie,</p><img src="https://x.example/open?m=1" border="0" width="1" height="1">"#))
        #expect(!MessagePage.hasPictures(#"<img src="https://x.example/p.gif" style="width:1px;height:1px;">"#))
        #expect(!MessagePage.hasPictures("<p>No images</p>"))
    }
}
