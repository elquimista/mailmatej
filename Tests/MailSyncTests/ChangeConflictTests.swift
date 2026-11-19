import Foundation
import JMAPKit
import MailStore
import Testing

@testable import MailSync

/// Stalwart refuses a change to a message something else is changing at that moment ("forbidden:
/// Another process modified this message, please try again."): the change is made again.
@Suite struct ChangeConflictTests {
    @Test func aChangeRefusedForAConflictIsMadeAgain() async throws {
        let server = StubJMAP.Server(conflicts: ["m1": 2])
        let sync = try server.engine()
        try await sync.update(remoteIds: ["m1", "m2"], patch: ["keywords/$seen": .bool(true)])
        #expect(server.calls == [["m1", "m2"], ["m1"], ["m1"]])
    }

    @Test func aConflictThatLastsIsReported() async throws {
        let server = StubJMAP.Server(conflicts: ["m1": 10])
        let sync = try server.engine()
        await #expect(throws: JMAPAccountSync.ChangeRefused.self) {
            try await sync.update(remoteIds: ["m1", "m2"], patch: ["keywords/$flagged": .bool(true)])
        }
        #expect(server.calls == [["m1", "m2"], ["m1"], ["m1"], ["m1"]])
    }

    @Test func otherRefusalsAreNotMadeAgain() async throws {
        let server = StubJMAP.Server(conflicts: [:], refused: ["m1"])
        let sync = try server.engine()
        await #expect(throws: JMAPAccountSync.ChangeRefused.self) {
            try await sync.update(remoteIds: ["m1"], patch: ["keywords/$flagged": .bool(true)])
        }
        #expect(server.calls == [["m1"]])
    }

    @Test func aDeleteRefusedForAConflictIsMadeAgain() async throws {
        let server = StubJMAP.Server(conflicts: ["m2": 1])
        let sync = try server.engine()
        try await sync.destroy(remoteIds: ["m1", "m2"])
        #expect(server.calls == [["m1", "m2"], ["m2"]])
    }
}

/// A JMAP server answering in the test process: its session, Email/set as `Server` says, Email/get with nothing.
final class StubJMAP: URLProtocol, @unchecked Sendable {
    final class Server: @unchecked Sendable {
        let host = "\(UUID().uuidString.lowercased()).test"
        private let lock = NSLock()
        /// How many more times each message's change is refused for a conflict.
        private var conflicts: [String: Int]
        /// Messages whose changes are refused for good (forbidden, without a conflict).
        private let refused: Set<String>
        private var recorded: [[String]] = []
        /// Uploads larger than this are refused with 413 and an HTML page, as a proxy in front of the server does.
        let uploadLimit: Int?
        /// The upload limit the session gives (its maxSizeUpload).
        let announcedLimit: Int?
        private var uploadCount = 0

        init(conflicts: [String: Int], refused: Set<String> = [], uploadLimit: Int? = nil, announcedLimit: Int? = nil) {
            self.conflicts = conflicts
            self.refused = refused
            self.uploadLimit = uploadLimit
            self.announcedLimit = announcedLimit
            StubJMAP.register(self)
        }

        /// How many uploads reached the server.
        var uploads: Int { lock.withLock { uploadCount } }
        func uploaded() -> Int { lock.withLock { uploadCount += 1; return uploadCount } }

        /// The ids of each Email/set made, sorted.
        var calls: [[String]] { lock.withLock { recorded } }

        var account: AccountRecord {
            AccountRecord(id: "a", name: "A", sessionURL: "https://\(host)/session", username: "a", authKind: .basic, remoteAccountId: "A")
        }

        func engine(store: MailStore? = nil) throws -> JMAPAccountSync {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [StubJMAP.self]
            return try JMAPAccountSync(
                account: account, credentials: .basic(username: "a", password: "p"), store: try store ?? MailStore(directory: directory),
                urlSession: URLSession(configuration: config))
        }

        func answer(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
            guard name == "Email/set" else { return ["accountId": "A", "state": "1", "list": [], "notFound": []] }
            if let create = arguments["create"] as? [String: Any] {
                return ["accountId": "A", "newState": "2", "created": create.mapValues { _ in ["id": "M\(UUID().uuidString.prefix(8))"] }]
            }
            let ids = ((arguments["update"] as? [String: Any]).map { Array($0.keys) } ?? arguments["destroy"] as? [String] ?? []).sorted()
            let deleting = arguments["destroy"] != nil
            return lock.withLock {
                recorded.append(ids)
                var done: [String: Any] = [:]
                var notDone: [String: Any] = [:]
                for id in ids {
                    if let left = conflicts[id], left > 0 {
                        conflicts[id] = left - 1
                        notDone[id] = ["type": "forbidden", "description": "Another process modified this message, please try again."]
                    } else if refused.contains(id) {
                        notDone[id] = ["type": "forbidden", "description": "Not allowed."]
                    } else {
                        done[id] = NSNull()
                    }
                }
                return deleting
                    ? ["accountId": "A", "newState": "2", "destroyed": Array(done.keys), "notDestroyed": notDone]
                    : ["accountId": "A", "newState": "2", "updated": done, "notUpdated": notDone]
            }
        }
    }

    nonisolated(unsafe) private static var servers: [String: Server] = [:]
    private static let lock = NSLock()

    static func register(_ server: Server) { lock.withLock { servers[server.host] = server } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let server = Self.lock.withLock({ Self.servers[url.host ?? ""] }) else {
            return client!.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
        }
        let body: Any
        if url.path.hasPrefix("/upload/") {
            let size = Self.read(request).count
            let number = server.uploaded()
            if let limit = server.uploadLimit, size > limit {
                return reply(url, 413, Data("<html><body><h1>413 Request Entity Too Large</h1></body></html>".utf8), type: "text/html")
            }
            body = ["accountId": "A", "blobId": "B\(number)", "type": "image/png", "size": size]
        } else if url.path == "/session" {
            var core: [String: Any] = ["maxObjectsInGet": 500, "maxObjectsInSet": 500]
            if let limit = server.announcedLimit { core["maxSizeUpload"] = limit }
            body = [
                "capabilities": ["urn:ietf:params:jmap:core": core, "urn:ietf:params:jmap:mail": [:], "urn:ietf:params:jmap:submission": [:]],
                "accounts": ["A": ["name": "a", "isPersonal": true, "isReadOnly": false, "accountCapabilities": ["urn:ietf:params:jmap:mail": [:]]]],
                "primaryAccounts": ["urn:ietf:params:jmap:mail": "A"], "username": "a", "apiUrl": "https://\(server.host)/api",
                "downloadUrl": "https://\(server.host)/download/{accountId}/{blobId}/{name}?type={type}",
                "uploadUrl": "https://\(server.host)/upload/{accountId}/", "eventSourceUrl": "https://\(server.host)/events", "state": "s",
            ]
        } else {
            let request = (try? JSONSerialization.jsonObject(with: Self.read(self.request))) as? [String: Any]
            let calls = request?["methodCalls"] as? [[Any]] ?? []
            body = [
                "sessionState": "s",
                "methodResponses": calls.map { call -> [Any] in
                    let name = call[0] as? String ?? ""
                    return [name, server.answer(name, call[1] as? [String: Any] ?? [:]), call[2]]
                },
            ]
        }
        reply(url, 200, try! JSONSerialization.data(withJSONObject: body), type: "application/json")
    }

    private func reply(_ url: URL, _ status: Int, _ data: Data, type: String) {
        client!.urlProtocol(
            self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": type])!,
            cacheStoragePolicy: .notAllowed)
        client!.urlProtocol(self, didLoad: data)
        client!.urlProtocolDidFinishLoading(self)
    }

    /// A request's body, which reaches a URLProtocol as a stream.
    private static func read(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
