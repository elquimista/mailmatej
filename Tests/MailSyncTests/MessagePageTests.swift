import Foundation
import Testing

@testable import MailSync

@Suite struct MessagePageTests {
    let headers = [
        MessagePage.HeaderField(label: "From:", value: "Eve <eve@x.com>"),
        MessagePage.HeaderField(label: "Subject:", value: "<b>Hi</b> & bye", emphasized: true),
        MessagePage.HeaderField(label: "Cc:", value: ""),
    ]

    @Test func headersAreEscapedAndEmptyOnesSkipped() {
        let page = MessagePage.html(headers: headers, bar: nil, content: "<p>x</p>", plain: false, remote: false, token: "T")
        #expect(page.contains("<mmj-value>Eve &lt;eve@x.com&gt;</mmj-value>"))
        #expect(page.contains(#"<mmj-value class="em">&lt;b&gt;Hi&lt;/b&gt; &amp; bye</mmj-value>"#))
        #expect(!page.contains("Cc:"))
        #expect(page.contains("<mmj-content><p>x</p></mmj-content>"))
        #expect(page.contains("script-src 'none'"))
        #expect(!page.contains("https:;"))  // no remote sources unless allowed
    }

    @Test func barOffersActionsOnlyWhenUseful() {
        let blocked = MessagePage.barHTML(
            MessagePage.Bar(remote: 5, strict: 2, loaded: false, canAlwaysLoad: true, allowedBy: []), token: "T")
        #expect(blocked.contains("Blocked 5 remote resources · 2 tracker or insecure resources always blocked"))
        #expect(blocked.contains(#"href="mmj-action:T/load""#))
        #expect(blocked.contains(#"href="mmj-action:T/alwaysLoadMenu""#))

        let onlyStrict = MessagePage.barHTML(
            MessagePage.Bar(remote: 1, strict: 1, loaded: false, canAlwaysLoad: true, allowedBy: []), token: "T")
        #expect(!onlyStrict.contains("<a "))

        let loaded = MessagePage.barHTML(
            MessagePage.Bar(remote: 3, strict: 0, loaded: true, canAlwaysLoad: true, allowedBy: ["@x.com"]), token: "T")
        #expect(loaded.contains("Loaded 3 remote resources"))
        #expect(loaded.contains("stopAlwaysLoading"))
    }

    @Test func actionLinksNeedThePageToken() {
        #expect(MessagePage.action(from: URL(string: "mmj-action:T/load")!, token: "T") == .load)
        #expect(MessagePage.action(from: URL(string: "mmj-action:OTHER/load")!, token: "T") == nil)
        #expect(MessagePage.action(from: URL(string: "mmj-action:T/bogus")!, token: "T") == nil)
        #expect(MessagePage.action(from: URL(string: "https://x.com/load")!, token: "T") == nil)
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
    }
}
