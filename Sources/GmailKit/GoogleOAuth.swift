import Foundation
import Network
import CryptoKit

/// The app's OAuth client in Google Cloud (a "Desktop app" client). Google treats a desktop app's
/// secret as public: it's sent when Google asks for it, but it protects nothing.
public struct GoogleClient: Sendable, Equatable {
    public var id: String
    public var secret: String?

    public init(id: String, secret: String?) {
        self.id = id
        self.secret = secret
    }

    /// The client in a JSON file as Google Cloud downloads it (`{"installed": {"client_id": …}}`).
    public init?(json data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let installed = (object["installed"] ?? object["web"]) as? [String: Any],
            let id = installed["client_id"] as? String, !id.isEmpty
        else { return nil }
        self.init(id: id, secret: installed["client_secret"] as? String)
    }
}

public enum GoogleOAuthError: LocalizedError, Equatable {
    case cancelled
    case denied(String)
    case timedOut
    case badResponse(String)
    /// The refresh token no longer works (revoked, expired, or the password changed): sign in again.
    case signInExpired

    public var errorDescription: String? {
        switch self {
        case .cancelled: "Signing in was cancelled."
        case .denied(let reason): "Google didn’t allow access (\(reason))."
        case .timedOut: "Signing in took too long. Try again."
        case .badResponse(let detail): "Google’s answer couldn’t be read (\(detail))."
        case .signInExpired: "Google needs you to sign in to this account again."
        }
    }
}

/// Signing in with Google as an installed app (Google's "OAuth 2.0 for iOS & Desktop Apps"): the
/// browser opens Google's consent page, which sends the code back to a one-off listener on
/// 127.0.0.1, exchanged with PKCE for a refresh token. Access tokens come from that token as needed.
public enum GoogleOAuth {
    static let authorizationURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    /// Full mail access (read, change, send and delete for good: Empty Deleted Messages needs it).
    public static let mailScope = "https://mail.google.com/"

    public struct Tokens: Sendable {
        public var refreshToken: String
        public var accessToken: String
        public var expiry: Date
    }

    /// Signs in through the browser (`open` shows the page) and returns the account's tokens.
    /// `loginHint` (an address) preselects the Google account. Gives up after `timeout`.
    public static func authorize(
        client: GoogleClient, loginHint: String?, timeout: Duration = .seconds(300),
        open: @escaping @Sendable (URL) -> Void
    ) async throws -> Tokens {
        let verifier = randomURLSafe(bytes: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = randomURLSafe(bytes: 16)
        let receiver = try await LoopbackReceiver.start()
        defer { receiver.stop() }
        let redirect = "http://127.0.0.1:\(receiver.port)"

        var components = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "client_id", value: client.id),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: mailScope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            // A refresh token every time, also for an account that agreed before.
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ] + (loginHint.map { [.init(name: "login_hint", value: $0)] } ?? [])
        open(components.url!)

        let query = try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask { try await receiver.request() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw GoogleOAuthError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        if let error = query["error"] { throw error == "access_denied" ? GoogleOAuthError.cancelled : GoogleOAuthError.denied(error) }
        guard query["state"] == state, let code = query["code"] else { throw GoogleOAuthError.badResponse("no code") }

        var form = ["code": code, "client_id": client.id, "redirect_uri": redirect, "grant_type": "authorization_code",
                    "code_verifier": verifier]
        form["client_secret"] = client.secret
        let answer = try await post(form)
        guard let refresh = answer["refresh_token"] as? String, let access = answer["access_token"] as? String else {
            throw GoogleOAuthError.badResponse("no refresh token")
        }
        return Tokens(refreshToken: refresh, accessToken: access, expiry: expiry(answer))
    }

    /// A fresh access token for a refresh token.
    public static func refresh(client: GoogleClient, refreshToken: String) async throws -> (token: String, expiry: Date) {
        var form = ["refresh_token": refreshToken, "client_id": client.id, "grant_type": "refresh_token"]
        form["client_secret"] = client.secret
        let answer: [String: Any]
        do {
            answer = try await post(form)
        } catch GoogleOAuthError.denied(let reason) where reason == "invalid_grant" {
            throw GoogleOAuthError.signInExpired
        }
        guard let access = answer["access_token"] as? String else { throw GoogleOAuthError.badResponse("no access token") }
        return (access, expiry(answer))
    }

    private static func expiry(_ answer: [String: Any]) -> Date {
        // A minute early, so a token isn't used as it runs out.
        Date().addingTimeInterval(TimeInterval((answer["expires_in"] as? Int) ?? 3600) - 60)
    }

    private static func post(_ form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GoogleOAuthError.denied(object["error"] as? String ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return object
    }

    static func randomURLSafe(bytes: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) }).base64URL
    }
}

/// Access tokens for one Google account, refreshed from its refresh token when they run out.
public actor GoogleTokenSource {
    private let client: GoogleClient
    private let refreshToken: String
    private var current: (token: String, expiry: Date)?

    public init(client: GoogleClient, refreshToken: String, accessToken: String? = nil, expiry: Date? = nil) {
        self.client = client
        self.refreshToken = refreshToken
        if let accessToken, let expiry { current = (accessToken, expiry) }
    }

    public func accessToken() async throws -> String {
        if let current, current.expiry > Date() { return current.token }
        let fresh = try await GoogleOAuth.refresh(client: client, refreshToken: refreshToken)
        current = fresh
        return fresh.token
    }

    /// Forgets the access token (the API refused it), so the next one is fetched anew.
    public func invalidate() { current = nil }
}

extension Data {
    /// Base64 without padding, with - and _ (RFC 4648 §5), as PKCE and Gmail's raw messages use it.
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A one-request HTTP listener on 127.0.0.1 (any free port) for the browser's redirect: it reads the
/// request's query, answers with a short page, and stops.
final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.mailmatej.google-oauth")
    private let lock = NSLock()
    private var waiting: CheckedContinuation<[String: String], Error>?
    private var received: Result<[String: String], Error>?
    private(set) var port: UInt16 = 0

    private init(listener: NWListener) { self.listener = listener }

    static func start() async throws -> LoopbackReceiver {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let receiver = LoopbackReceiver(listener: try NWListener(using: parameters))
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            receiver.listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    receiver.port = receiver.listener.port?.rawValue ?? 0
                    if once.claim() { ready.resume() }
                case .failed(let error):
                    if once.claim() { ready.resume(throwing: error) }
                    receiver.finish(.failure(error))
                default: break
                }
            }
            receiver.listener.newConnectionHandler = { receiver.handle($0) }
            receiver.listener.start(queue: receiver.queue)
        }
        return receiver
    }

    /// The redirect's query parameters, once the browser comes back.
    func request() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let received {
                    lock.unlock()
                    continuation.resume(with: received)
                } else {
                    waiting = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    func stop() { listener.cancel() }

    private func finish(_ result: Result<[String: String], Error>) {
        lock.lock()
        guard received == nil else { return lock.unlock() }
        received = result
        let continuation = waiting
        waiting = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            // "GET /?code=…&state=… HTTP/1.1"; other requests (a favicon) get the page and nothing else.
            let target = text.split(separator: " ", maxSplits: 2).dropFirst().first.map(String.init) ?? ""
            let items = URLComponents(string: target)?.queryItems ?? []
            let query = Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { a, _ in a })
            let page = """
                <!doctype html><meta charset="utf-8"><title>MailMateJ</title>
                <body style="font: 15px -apple-system, sans-serif; text-align: center; margin-top: 20vh">
                <p>\(query["error"] == nil ? "Signed in. You can close this tab and return to MailMateJ." : "Signing in didn’t finish. You can close this tab.")</p>
                """
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if query["code"] != nil || query["error"] != nil { self?.finish(.success(query)) }
        }
    }
}

/// True the first time it's claimed, for resuming a continuation once from callbacks.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
