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
        #expect(out.html.contains(#"src="data:," width="1""#))
        #expect(out.html.contains("product.png"))
        #expect(!out.html.contains("hidden.png"))
    }

    @Test func rulePatternsMatchExpectedURLs() {
        #expect(RemoteContentRules.isStrict("http://a.com/x.png"))
        #expect(RemoteContentRules.isStrict("https://ssl.google-analytics.com/collect?v=1"))
        #expect(!RemoteContentRules.isStrict("https://images.example.com/hero.jpg"))
        let json = RemoteContentRules.contentRuleListJSON(["^https?:"])
        #expect(json.contains(#""url-filter":"^https?:""#))
    }
}
