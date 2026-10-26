import Foundation
import Testing
@testable import GmailKit

struct GoogleOAuthTests {
    @Test func readsTheClientFileGoogleCloudDownloads() throws {
        let json = #"{"installed":{"client_id":"123-abc.apps.googleusercontent.com","project_id":"p","client_secret":"GOCSPX-x","redirect_uris":["http://localhost"]}}"#
        let client = try #require(GoogleClient(json: Data(json.utf8)))
        #expect(client.id == "123-abc.apps.googleusercontent.com" && client.secret == "GOCSPX-x")
        #expect(GoogleClient(json: Data("{}".utf8)) == nil)
    }

    @Test func base64URLHasNoPaddingOrUnsafeCharacters() {
        #expect(Data([0xfb, 0xff]).base64URL == "-_8")
        #expect(GoogleOAuth.randomURLSafe(bytes: 32).count == 43)
    }

    @Test func theLoopbackListenerHandsOverTheRedirectsQuery() async throws {
        let receiver = try await LoopbackReceiver.start()
        defer { receiver.stop() }
        #expect(receiver.port > 0)
        async let query = receiver.request()
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(receiver.port)/?state=s1&code=4%2Fabc")!)
        #expect(String(decoding: data, as: UTF8.self).contains("Signed in"))
        #expect(try await query == ["state": "s1", "code": "4/abc"])
    }
}
