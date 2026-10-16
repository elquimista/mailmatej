import Foundation
import JMAPKit
import MailStore
import Testing

@testable import MailSync

@Suite struct ErrorTextTests {
    @Test func unknownHostNamesTheServer() {
        let url = URL(string: "https://mail.example.com/.well-known/jmap")!
        let error = URLError(.cannotFindHost, userInfo: [NSURLErrorFailingURLErrorKey: url])
        #expect(ErrorText.friendly(error) == "Couldn’t find “mail.example.com”. Check the server address.")
    }

    @Test func bridgedNSErrorIsMapped() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(ErrorText.friendly(error) == "You’re offline. Check your internet connection.")
    }

    @Test func jmapErrors() {
        #expect(ErrorText.friendly(JMAPError.unauthorized).hasPrefix("The server rejected the sign-in"))
        #expect(ErrorText.friendly(JMAPError.http(status: 404, body: "")).hasPrefix("No JMAP service"))
        #expect(ErrorText.friendly(JMAPError.http(status: 503, body: "")) == "The server had a problem (HTTP 503). Try again later.")
    }

    @Test func problemDetailsAreShown() {
        let body = #"{"type":"urn:ietf:params:jmap:error:notRequest","status":400,"detail":"Invalid request"}"#
        #expect(ErrorText.friendly(JMAPError.http(status: 400, body: body))
            == "The server rejected the request (HTTP 400): Invalid request.")
    }

    @Test func technicalKeepsDetails() {
        #expect(ErrorText.technical(JMAPError.http(status: 418, body: "teapot")).contains("teapot"))
    }
}

@Suite struct DownloadHelpersTests {
    @Test func plainTextFromHTML() {
        let html = "<html><head><style>p{color:red}</style></head><body><p>Hello&nbsp;<b>there</b></p><p>A &amp; B</p></body></html>"
        #expect(JMAPAccountSync.plainText(fromHTML: html) == "Hello there\nA & B")
    }

    @Test func groupsRespectSizeLimit() {
        func item(_ id: Int64, _ size: Int) -> MailStore.PendingDownload {
            MailStore.PendingDownload(id: id, remoteId: "r\(id)", blobId: "b\(id)", size: size, hasBody: false)
        }
        let groups = JMAPAccountSync.groups([item(1, 300), item(2, 300), item(3, 500), item(4, 2000)], maxBytes: 1000)
        #expect(groups.map { $0.map(\.id) } == [[1, 2], [3], [4]])
    }
}
