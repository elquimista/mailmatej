import Foundation

public enum Credentials: Sendable {
    case basic(username: String, password: String)
    case bearer(token: String)

    var authorizationHeader: String {
        switch self {
        case .basic(let u, let p): "Basic " + Data("\(u):\(p)".utf8).base64EncodedString()
        case .bearer(let t): "Bearer " + t
        }
    }
}

/// A connection to one JMAP server as one user. Holds the cached Session.
public actor JMAPClient {
    public let sessionURL: URL
    private let credentials: Credentials
    private let urlSession: URLSession
    private var session: Session?

    public init(sessionURL: URL, credentials: Credentials, urlSession: URLSession = .shared) {
        self.sessionURL = sessionURL
        self.credentials = credentials
        self.urlSession = urlSession
    }

    /// Turns what a user types ("mail.example.com", "https://host", or a full session URL)
    /// into a session URL, defaulting to the RFC 8620 `.well-known/jmap` autodiscovery path.
    public static func sessionURL(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text), components.host != nil else { return nil }
        if components.path.isEmpty || components.path == "/" { components.path = "/.well-known/jmap" }
        return components.url
    }

    // MARK: Session

    @discardableResult
    public func fetchSession() async throws -> Session {
        let (data, _) = try await perform(authorized(URLRequest(url: sessionURL)))
        var fresh = try JMAPCoding.decoder.decode(Session.self, from: data)
        if let host = sessionURL.host, ["localhost", "127.0.0.1", "::1"].contains(host) {
            fresh = fresh.rebased(onto: sessionURL)
        }
        session = fresh
        return fresh
    }

    public func currentSession() async throws -> Session {
        if let session { return session }
        return try await fetchSession()
    }

    // MARK: API

    public func send(_ request: JMAPRequest) async throws -> JMAPResponse {
        let session = try await currentSession()
        var http = authorized(URLRequest(url: session.apiUrl))
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.httpBody = try request.encoded()
        let (data, _) = try await perform(http)
        let response = try JMAPResponse(data: data)
        if let state = response.sessionState, state != session.state {
            self.session = nil  // Refetch lazily; capabilities or accounts changed.
        }
        return response
    }

    public func download(accountId: String, blobId: String, type: String, name: String) async throws -> Data {
        let session = try await currentSession()
        guard let url = session.downloadURL(accountId: accountId, blobId: blobId, type: type, name: name) else {
            throw JMAPError.invalidResponse("bad downloadUrl template")
        }
        return try await perform(authorized(URLRequest(url: url))).0
    }

    // MARK: Push

    /// Streams push signals over EventSource (RFC 8620 §7.3) until cancelled or the connection drops.
    /// The server pings every 30 s; if no bytes arrive for `silenceTimeout` (e.g. a proxy buffers the
    /// stream), the request times out and the stream ends with an error.
    public func eventSourceSignals(silenceTimeout: TimeInterval = 75) async throws -> AsyncThrowingStream<PushSignal, Error> {
        let session = try await currentSession()
        guard let url = session.eventSourceURL() else { throw JMAPError.invalidResponse("bad eventSourceUrl") }
        var request = authorized(URLRequest(url: url))
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.timeoutInterval = silenceTimeout
        let (bytes, response) = try await urlSession.bytes(for: request, delegate: RedirectAuthDelegate.shared)
        try check(response, body: Data())

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var parser = EventStreamParser()
                    for try await byte in bytes {
                        guard let event = parser.feed(byte) else { continue }
                        if event.type == "state", let data = event.data.data(using: .utf8),
                            let change = try? JSONDecoder().decode(StateChange.self, from: data)
                        {
                            continuation.yield(.changed(change))
                        } else {
                            continuation.yield(.alive)  // "ping" and anything else prove the stream flows.
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Streams push signals over a JMAP WebSocket (RFC 8887). Unlike EventSource, proxies don't buffer
    /// WebSocket traffic. The connection is checked with a WebSocket ping every 30 s.
    public func webSocketSignals() async throws -> AsyncThrowingStream<PushSignal, Error> {
        let session = try await currentSession()
        guard let url = session.webSocketURL else { throw JMAPError.missingCapability(Capability.webSocket) }
        var request = authorized(URLRequest(url: url))
        request.setValue("jmap", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let task = urlSession.webSocketTask(with: request)
        task.resume()
        // Fails here if the handshake fails (e.g. a proxy that doesn't pass WebSocket upgrades).
        try await task.send(.string(#"{"@type":"WebSocketPushEnable","dataTypes":null}"#))

        return AsyncThrowingStream { continuation in
            let receiver = Task {
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        let data: Data? =
                            switch message {
                            case .string(let text): text.data(using: .utf8)
                            case .data(let data): data
                            @unknown default: nil
                            }
                        if let data, let json = try? JSONDecoder().decode(JSONValue.self, from: data),
                            json["@type"]?.stringValue == "StateChange",
                            let change = try? json.decode(StateChange.self)
                        {
                            continuation.yield(.changed(change))
                        } else {
                            continuation.yield(.alive)
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let pinger = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { return }
                    if await Self.ping(task, timeout: .seconds(20)) {
                        continuation.yield(.alive)
                    } else {
                        task.cancel(with: .goingAway, reason: nil)  // Dead connection; ends the receiver too.
                        return
                    }
                }
            }
            continuation.onTermination = { _ in
                receiver.cancel()
                pinger.cancel()
                task.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    /// Sends a WebSocket ping; true if the pong arrives within `timeout`.
    private static func ping(_ task: URLSessionWebSocketTask, timeout: Duration) async -> Bool {
        let result = PongResult()
        task.sendPing { error in result.set(error == nil) }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let answered = result.value { return answered }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    // MARK: HTTP

    private func authorized(_ request: URLRequest) -> URLRequest {
        var r = request
        r.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
        return r
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await urlSession.data(for: request, delegate: RedirectAuthDelegate.shared)
        return (data, try check(response, body: data))
    }

    @discardableResult
    private func check(_ response: URLResponse, body: Data) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw JMAPError.invalidResponse("not HTTP") }
        switch http.statusCode {
        case 200..<300: return http
        case 401, 403: throw JMAPError.unauthorized
        default:
            throw JMAPError.http(status: http.statusCode, body: String(decoding: body, as: UTF8.self), url: http.url)
        }
    }
}

/// What a push connection delivers.
public enum PushSignal: Sendable {
    /// Something changed on the server.
    case changed(StateChange)
    /// A ping or other traffic: the connection works.
    case alive
}

/// Thread-safe holder for a WebSocket pong result.
final class PongResult: @unchecked Sendable {
    private let lock = NSLock()
    private var answered: Bool?
    func set(_ value: Bool) { lock.withLock { answered = value } }
    var value: Bool? { lock.withLock { answered } }
}

/// Keeps the Authorization header across same-host redirects
/// (e.g. `/.well-known/jmap` → `/jmap/session`), and drops it for other hosts.
final class RedirectAuthDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = RedirectAuthDelegate()

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        var redirected = request
        if let original = task.originalRequest, original.url?.host == request.url?.host,
            let auth = original.value(forHTTPHeaderField: "Authorization")
        {
            redirected.setValue(auth, forHTTPHeaderField: "Authorization")
        } else {
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return redirected
    }
}

/// Minimal `text/event-stream` parser. Fed one byte at a time; returns an event on each blank line.
struct EventStreamParser {
    struct Event {
        var type: String
        var data: String
    }

    private var line: [UInt8] = []
    private var eventType = ""
    private var dataLines: [String] = []

    mutating func feed(_ byte: UInt8) -> Event? {
        if byte == UInt8(ascii: "\r") { return nil }
        guard byte == UInt8(ascii: "\n") else {
            line.append(byte)
            return nil
        }
        let text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)

        if text.isEmpty {
            defer {
                eventType = ""
                dataLines = []
            }
            guard !dataLines.isEmpty else { return nil }
            return Event(type: eventType.isEmpty ? "message" : eventType, data: dataLines.joined(separator: "\n"))
        }
        if text.hasPrefix(":") { return nil }  // Comment / keep-alive.
        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(text)
            value = ""
        }
        switch field {
        case "event": eventType = String(value)
        case "data": dataLines.append(String(value))
        default: break
        }
        return nil
    }
}
