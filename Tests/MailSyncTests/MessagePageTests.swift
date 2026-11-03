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

    @Test func barSaysWhatMailMateSays() {
        let image = RemoteResource(url: "https://cdn.x.com/a.png", kind: "img src")
        let font = RemoteResource(url: "https://cdn.x.com/f.woff2", kind: "stylesheet")
        let tracker = RemoteResource(url: "https://s.x.com/wf/open?u=1", kind: "img src", strictType: .knownTracker)

        let plain = MessagePage.Bar(resources: [image, font], loaded: false)
        #expect(plain.text == "Detected 2 external resources")
        #expect(plain.level == .yellow)
        #expect(plain.actions.map(\.title) == ["Download (2)"])

        let risky = MessagePage.Bar(resources: [tracker, image, font], loaded: false)
        #expect(risky.text == "Detected 3 external resources of which 1 is strictly blocked")
        #expect(risky.level == .orange)
        #expect(risky.actions.map(\.title) == ["Download (2)"])  // strictly blocked ones never load
        #expect(risky.details.map(\.label) == ["Risk analysis", "Strictly blocked (1)", "Blocked (2)"])
        #expect(risky.details[1].lines == ["Type: Known tracker", "https://s.x.com/wf/open?u=1 (img src)"])
        #expect(risky.details[2].lines == ["https://cdn.x.com/a.png (img src)", "https://cdn.x.com/f.woff2 (stylesheet)"])

        let onlyStrict = MessagePage.Bar(resources: [tracker], loaded: false)
        #expect(onlyStrict.actions.isEmpty)

    }

    /// Once downloaded: red if a 1 by 1 image came (as MailMate's), otherwise the same yellow or orange
    /// bar; each with Reload (to block them again).
    @Test func barAfterDownloading() {
        let image = RemoteResource(url: "https://cdn.x.com/a.png", kind: "img src")
        let tracker = RemoteResource(url: "https://s.x.com/wf/open?u=1", kind: "img src", strictType: .knownTracker)

        let pixel = MessagePage.Bar(resources: [image], loaded: true, downloadedPixels: 1)
        #expect(pixel.level == .red)
        #expect(pixel.text == "An image with a pixel size of 1 by 1 has been downloaded")
        #expect(pixel.actions.map(\.action) == [.reload])
        #expect(MessagePage.Bar(resources: [image], loaded: true, downloadedPixels: 2).text
            == "2 images with a pixel size of 1 by 1 have been downloaded")

        let strict = MessagePage.Bar(resources: [tracker, image], loaded: true)
        #expect(strict.level == .orange)
        #expect(strict.text == "Detected 2 external resources of which 1 is strictly blocked")
        #expect(strict.actions.map(\.title) == ["Reload"])
        #expect(strict.details.last?.label == "Downloaded (1)")

        let plain = MessagePage.Bar(resources: [image], loaded: true)
        #expect(plain.level == .yellow)
        #expect(plain.text == "Detected 1 external resource")
        #expect(plain.actions.map(\.action) == [.reload])
    }

    @Test func plainTextQuotesBecomeNestedBlocksWithoutMarkers() {
        let html = MessagePage.plainHTML("Yes!\n\nOn 19 Oct, A wrote:\n\n> This <is>\n>> older\n> back\nAfter")
        #expect(html == "<mmj-line>Yes!</mmj-line><mmj-line><br></mmj-line><mmj-line>On 19 Oct, A wrote:</mmj-line>"
            + "<mmj-line><br></mmj-line><mmj-quote><mmj-line>This &lt;is&gt;</mmj-line>"
            + "<mmj-quote><mmj-line>older</mmj-line></mmj-quote><mmj-line>back</mmj-line></mmj-quote>"
            + "<mmj-line>After</mmj-line>")
    }

    @Test func rawSourceShowsAsTextThatLoadsNothing() {
        let source = "Subject: Hi\r\nContent-Type: text/html\r\n\r\n<img src=\"https://x.example/p.gif\">caf\u{e9}\r\n"
        let utf8 = MessagePage.rawHTML(Data(source.utf8))
        #expect(utf8.contains("<mmj-content>Subject: Hi\nContent-Type: text/html\n\n&lt;img src=&quot;https://x.example/p.gif&quot;&gt;café\n</mmj-content>"))
        #expect(utf8.contains("default-src 'none'; style-src 'unsafe-inline'\""))
        // Not UTF-8 (an 8-bit Latin-1 body): byte for byte, nothing dropped.
        let latin1 = MessagePage.rawHTML(source.data(using: .isoLatin1)!)
        #expect(latin1.contains("café\n</mmj-content>"))
        // Only a CR that ends a line with LF goes.
        #expect(MessagePage.rawEscaped(Data("a\rb\r\r\n".utf8)) == Array("a\rb\r\n".utf8))
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

    /// HTML with colours shows light even with dark mode of its own (its web view is light then):
    /// ADP's sets its text white for dark mode, on a card it keeps white.
    @Test func htmlWithItsOwnDarkModeShowsLight() {
        let adp = """
            <style>:root { color-scheme: light dark; } @media (prefers-color-scheme: dark) { p { color: #ffffff !important; } }</style>
            <table bgcolor="#fefefe"><tr><td><p style="color: rgb(74, 74, 74);">Register</p></td></tr></table>
            """
        #expect(!MessagePage.adapts(adp, plain: false))
        #expect(!MessagePage.html(content: adp, plain: false, remote: false).contains(#"<meta name="color-scheme""#))
        #expect(MessagePage.adapts("<p>Hi Ellie,</p>", plain: false))
        #expect(MessagePage.adapts(MessagePage.plainHTML("Hi"), plain: true))
    }
}
