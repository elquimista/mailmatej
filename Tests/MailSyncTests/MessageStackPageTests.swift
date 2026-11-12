import Foundation
import Testing

@testable import MailSync

@Suite struct MessageStackPageTests {
    /// One card per message, in order: its fields (empty ones left out, text escaped) and a frame for its
    /// content; the page itself loads nothing but those frames.
    @Test func cardsHoldTheFieldsAndAFrameEach() {
        let page = MessageStackPage.html(cards: [
            .init(id: 7, fields: [.init("From:", "Ann <ann@x.com>"), .init("Date:", "Today", searched: false), .init("Cc:", "")]),
            .init(id: 9, fields: [.init("From:", "Bob")]),
        ], detailsOpen: false)
        #expect(page.contains("<tr><td>From:</td><td>Ann &lt;ann@x.com&gt;</td></tr>"))
        #expect(page.contains("<tr data-nosearch><td>Date:</td><td>Today</td></tr>"))  // a search doesn't mark it
        #expect(!page.contains("Cc:"))
        #expect(page.range(of: "id=\"c7\"")!.lowerBound < page.range(of: "id=\"c9\"")!.lowerBound)
        #expect(page.contains("src=\"mmj-stack://stack/m/7/0\""))
        #expect(page.contains("default-src 'none'"))
        #expect(page.contains("frame-src mmj-stack:"))
        #expect(!page.contains("https:"))
        #expect(page.hasSuffix("<mmj-end></mmj-end></body></html>"))
        #expect(!page.contains("class=\"mmj-open\""))
        #expect(MessageStackPage.html(cards: [], detailsOpen: true).contains("<body class=\"mmj-open\">"))
    }

    @Test func frameURLsNameTheMessageAndGeneration() {
        let url = URL(string: MessageStackPage.frameURL(id: 42, generation: 3))!
        #expect(MessageStackPage.frame(of: url)! == (42, 3))
        #expect(MessageStackPage.frame(of: MessageStackPage.pageURL) == nil)
        #expect(MessageStackPage.frame(of: URL(string: "mmj-cid://42/m/1/2")!) == nil)
    }

    /// The bar as the single message's, plus Download All when other cards have remote content too.
    @Test func barOffersDownloadAllWhenOthersHaveMore() {
        let image = RemoteResource(url: "https://cdn.x.com/a.png", kind: "img src")
        let tracker = RemoteResource(url: "https://s.x.com/wf/open?u=1", kind: "img src", strictType: .knownTracker)
        let bar = MessagePage.Bar(resources: [tracker, image], loaded: false)
        let alone = MessageStackPage.extras(attachments: [], bar: bar, downloadAll: 1)
        #expect(alone.contains("<mmj-bar class=\"orange\">"))
        #expect(alone.contains("<mmj-button data-act=\"load\">Download (1)</mmj-button>"))
        #expect(!alone.contains("Download All"))
        let more = MessageStackPage.extras(attachments: [], bar: bar, downloadAll: 4)
        #expect(more.contains("<mmj-button data-act=\"loadAll\">Download All (4)</mmj-button><mmj-button data-act=\"load\">Download (1)</mmj-button>"))
        let loaded = MessageStackPage.extras(attachments: [], bar: MessagePage.Bar(resources: [image], loaded: true), downloadAll: 4)
        #expect(loaded.contains("data-act=\"reload\">Reload<"))
        #expect(!loaded.contains("Download ("))
        #expect(!loaded.contains("Download All"))
        let files = MessageStackPage.extras(
            attachments: [.init(name: "a<b>.pdf", size: "1.0 KiB", icon: nil)], bar: nil, downloadAll: 0)
        #expect(files == "<mmj-files><mmj-file data-i=\"0\"><img><span>a&lt;b&gt;.pdf</span><span>1.0 KiB</span></mmj-file></mmj-files>")
    }

    /// In a stack, an email that keeps its own colours stays light: its dark rules never apply, its
    /// light ones always do, on white; one that follows dark mode is left as it is.
    @Test func lightOnlyEmailsKeepTheirLightStyles() {
        let css = "<style>@media (prefers-color-scheme: dark) { p { color: #fff } } @media (prefers-color-scheme:light) { p { color: #000 } }</style>"
        #expect(MessagePage.lightOnly(css)
            == "<style>@media (max-width: 0px) { p { color: #fff } } @media (min-width: 0px) { p { color: #000 } }</style>")
        let light = MessagePage.html(content: css, plain: false, remote: false, adaptive: false, stacked: true)
        #expect(light.contains("max-width: 0px"))
        #expect(light.contains("color-scheme: light only"))
        #expect(light.contains("margin: 8px !important"))
        let adaptive = MessagePage.html(content: "<p>x</p>", plain: true, remote: false, adaptive: true, stacked: true)
        #expect(!adaptive.contains("light only"))
        #expect(adaptive.contains("margin: 8px !important"))
        // The single message's page is as before.
        #expect(!MessagePage.html(content: css, plain: false, remote: false, adaptive: false).contains("max-width: 0px"))
    }
}
