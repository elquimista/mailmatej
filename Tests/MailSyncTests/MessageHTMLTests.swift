import Foundation
import Testing

@testable import MailSync

@Suite struct MessageHTMLTests {
    @Test func rewritesEmbeddedImages() {
        let out = MessageHTML.prepare(#"<img src="cid:logo@trova.com"><td background=cid:bg%40x>"#, messageId: 42)
        #expect(out.html == #"<img src="mmj-cid://42/logo@trova.com"><td background=mmj-cid://42/bg@x>"#)
        #expect(out.remoteCount == 0)
    }

    @Test func countsRemoteResourcesOnce() {
        let html = """
            <link rel="stylesheet" href="https://cdn.example.com/a.css">
            <a href="https://example.com/not-a-resource">link</a>
            <img src="https://img.example.com/1.png"><img src='https://img.example.com/1.png'>
            <img srcset="https://img.example.com/2.png 1x, https://img.example.com/3.png 2x">
            <div style="background: url('https://img.example.com/4.png')"></div>
            """
        let out = MessageHTML.prepare(html, messageId: 1)
        #expect(out.remoteCount == 5)  // a.css, 1.png, 2.png, 3.png, 4.png — not the <a> link
        #expect(out.strictCount == 0)
        // In the page's order, with what refers to them, as MailMate lists them.
        #expect(out.resources.map(\.kind) == ["stylesheet", "img src", "img srcset", "img srcset", "stylesheet"])
        #expect(out.resources.map(\.url).last == "https://img.example.com/4.png")
    }

    @Test func strictTierCoversInsecureTrackersAndPixels() {
        let html = """
            <img src="http://insecure.example.com/x.png">
            <img src="https://us1.list-manage.com/track/open.php?u=1">
            <img src="https://shop.example.com/banner.png" width="1" height="1">
            <img src="https://shop.example.com/hidden.png" style="display:none">
            <img src="https://shop.example.com/product.png" width="120" height="80">
            """
        let out = MessageHTML.prepare(html, messageId: 1)
        #expect(out.remoteCount == 5)
        #expect(out.strictCount == 4)
        #expect(out.resources.map(\.strictType) == [.insecure, .knownTracker, .trackingPixel, .trackingPixel, nil])
        #expect(out.html.contains(#"src="data:," width="1""#))
        #expect(!out.html.contains("hidden.png\""))
    }

    @Test func blockedImagesBecomePlaceholdersAtTheirSize() {
        let html = #"<img alt="LE &amp; Co" src="https://cdn.x.com/a.webp" srcset="https://cdn.x.com/a2.webp 2x" width="32" height="32">"#
        let blocked = MessageHTML.prepare(html, messageId: 1, blockRemote: true).html
        #expect(blocked.contains(MessageHTML.blockedImagePlaceholder(alt: "LE & Co")))
        #expect(blocked.contains(#"title="Blocked: https://cdn.x.com/a.webp""#))
        #expect(blocked.contains(#"width="32" height="32""#))
        #expect(!blocked.contains("srcset"))
        #expect(!blocked.contains(#"src="https://"#))  // the remote source is gone (only the tooltip keeps it)

        let loaded = MessageHTML.prepare(html, messageId: 1, blockRemote: false).html
        #expect(loaded == html)

        let insecure = MessageHTML.prepare(#"<img src="http://x.com/a.png">"#, messageId: 1, blockRemote: false).html
        #expect(insecure.contains("data:image/svg+xml"))  // strict: boxed even when loading
        #expect(insecure.contains(#"width="40" height="40""#))  // no size given, no alt
    }

    @Test func placeholderShowsAltText() throws {
        let uri = MessageHTML.blockedImagePlaceholder(alt: "Logo <Trova>")
        let data = try #require(Data(base64Encoded: String(uri.dropFirst("data:image/svg+xml;base64,".count))))
        let svg = String(decoding: data, as: UTF8.self)
        #expect(svg.contains(">Logo &lt;Trova&gt;</text>"))
        #expect(MessageHTML.placeholderSize(alt: "Company logo").height == 20)
    }

    @Test func genericSansSerifIsPinnedToHelveticaInCSSOnly() {
        let html = """
            <style>td { font-family: Arial, sans-serif !important; }</style>
            <p style="font: bold 16px sans-serif">Text about sans-serif fonts</p><font face='sans-serif'>x</font>
            """
        let out = MessageHTML.prepare(html, messageId: 1).html
        #expect(out.contains("font-family: Arial, Helvetica, sans-serif !important"))
        #expect(out.contains(#"style="font: bold 16px Helvetica, sans-serif""#))
        #expect(out.contains("face='Helvetica, sans-serif'"))
        #expect(out.contains("Text about sans-serif fonts"))  // body text untouched
    }

    @Test func rulePatternsMatchExpectedURLs() {
        #expect(RemoteContentRules.isStrict("http://a.com/x.png"))
        #expect(RemoteContentRules.isStrict("https://ssl.google-analytics.com/collect?v=1"))
        #expect(!RemoteContentRules.isStrict("https://images.example.com/hero.jpg"))
        let json = RemoteContentRules.contentRuleListJSON(["^https?:"])
        #expect(json.contains(#""url-filter":"^https?:""#))
    }
}
