import Foundation

/// The Gmail API (https://developers.google.com/gmail/api) for one account, signed in with Google.
public struct GmailClient: Sendable {
    static let base = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/")!

    private let tokens: GoogleTokenSource
    private let session: URLSession
    /// The account's share of Gmail's quota (shared by copies of this client).
    private let quota = QuotaGate()

    public init(tokens: GoogleTokenSource, session: URLSession = .shared) {
        self.tokens = tokens
        self.session = session
    }

    // MARK: Account

    public struct Profile: Decodable, Sendable {
        public var emailAddress: String
        public var messagesTotal: Int?
        public var historyId: String?
    }

    /// The account's address and mailbox size.
    public func profile() async throws -> Profile {
        try decode(Profile.self, try await get("profile", cost: 1))
    }

    // MARK: Labels

    public struct Label: Decodable, Sendable {
        public var id: String
        public var name: String
        /// "system" or "user".
        public var type: String?
    }

    public func labels() async throws -> [Label] {
        struct List: Decodable { var labels: [Label]? }
        return try decode(List.self, try await get("labels", cost: 1)).labels ?? []
    }

    // MARK: Messages

    public struct MessageRef: Decodable, Sendable {
        public var id: String
        public var threadId: String?
    }

    /// One page of the account's messages, newest first, Spam and Trash included.
    public func listMessages(pageToken: String?, pageSize: Int = 500) async throws -> (messages: [MessageRef], next: String?) {
        struct List: Decodable {
            var messages: [MessageRef]?
            var nextPageToken: String?
        }
        var query = [URLQueryItem(name: "maxResults", value: String(pageSize)), URLQueryItem(name: "includeSpamTrash", value: "true")]
        if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        let list = try decode(List.self, try await get("messages", query: query, cost: 5))
        return (list.messages ?? [], list.nextPageToken)
    }

    public enum Format: String, Sendable {
        /// Its quota cost (Gmail's table: whole messages cost three times as much as their headers).
        var cost: Double { self == .full || self == .raw ? 60 : 20 }

        /// Labels and sizes only.
        case minimal
        /// Labels and the headers asked for.
        case metadata
        /// Labels, headers and every part (small ones' data included, larger ones by attachment id).
        case full
        /// The whole message as sent (RFC 5322), in `raw`.
        case raw
    }

    /// A message; nil if it no longer exists.
    public func message(_ id: String, format: Format, headers: [String] = []) async throws -> Message? {
        var query = [URLQueryItem(name: "format", value: format.rawValue)]
        query += headers.map { URLQueryItem(name: "metadataHeaders", value: $0) }
        do {
            return try decode(Message.self, try await get("messages/\(id)", query: query, cost: format.cost))
        } catch let error as APIError where error.status == 404 {
            return nil
        }
    }

    /// An attachment's data (a part too large to come with the message).
    public func attachment(messageId: String, attachmentId: String) async throws -> Data {
        struct Body: Decodable { var data: String? }
        let body = try decode(Body.self, try await get("messages/\(messageId)/attachments/\(attachmentId)", cost: 20))
        guard let data = body.data.flatMap(Data.init(base64URL:)) else { throw APIError(status: 0, message: "empty attachment") }
        return data
    }

    // MARK: Changes

    /// Adds and removes labels on up to 1,000 messages at once (messages already without a label to
    /// remove are fine).
    public func modify(_ ids: [String], add: [String], remove: [String]) async throws {
        for chunk in stride(from: 0, to: ids.count, by: 1000).map({ Array(ids[$0..<min($0 + 1000, ids.count)]) }) {
            _ = try await send("POST", "messages/batchModify", json: [
                "ids": chunk, "addLabelIds": add, "removeLabelIds": remove,
            ], cost: 50)
        }
    }

    /// Deletes messages for good (not to Trash), up to 1,000 at once.
    public func delete(_ ids: [String]) async throws {
        for chunk in stride(from: 0, to: ids.count, by: 1000).map({ Array(ids[$0..<min($0 + 1000, ids.count)]) }) {
            _ = try await send("POST", "messages/batchDelete", json: ["ids": chunk], cost: 50)
        }
    }

    /// Creates a label ("Work/Clients" nests it under "Work").
    public func createLabel(_ name: String) async throws -> Label {
        try decode(Label.self, try await send("POST", "labels", json: [
            "name": name, "labelListVisibility": "labelShow", "messageListVisibility": "show",
        ], cost: 5))
    }

    public func renameLabel(_ id: String, to name: String) async throws {
        _ = try await send("PATCH", "labels/\(id)", json: ["name": name], cost: 5)
    }

    /// Adds a whole raw message to the account with these labels, as if it had arrived (dated by its
    /// Date header).
    public func importMessage(_ raw: Data, labels: [String]) async throws {
        let boundary = "mmj-" + UUID().uuidString
        var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
        body += try JSONSerialization.data(withJSONObject: ["labelIds": labels])
        body += Data("\r\n--\(boundary)\r\nContent-Type: message/rfc822\r\n\r\n".utf8)
        body += raw
        body += Data("\r\n--\(boundary)--\r\n".utf8)
        let url = URL(string: "https://gmail.googleapis.com/upload/gmail/v1/users/me/messages/import")!
        _ = try await send("POST", url: url, query: [
            URLQueryItem(name: "uploadType", value: "multipart"), URLQueryItem(name: "internalDateSource", value: "dateHeader"),
        ], body: body, contentType: "multipart/related; boundary=\(boundary)", cost: 25)
    }

    // MARK: History

    public struct HistoryPage: Decodable, Sendable {
        public struct Record: Decodable, Sendable {
            public struct Change: Decodable, Sendable { public var message: MessageRef }
            public var messagesAdded: [Change]?
            public var messagesDeleted: [Change]?
            public var labelsAdded: [Change]?
            public var labelsRemoved: [Change]?
        }
        public var history: [Record]?
        public var nextPageToken: String?
        public var historyId: String?
    }

    /// Changes since `startHistoryId`. Throws `historyExpired` when Gmail no longer has that far back.
    public func history(since startHistoryId: String, pageToken: String?) async throws -> HistoryPage {
        var query = [URLQueryItem(name: "startHistoryId", value: startHistoryId), URLQueryItem(name: "maxResults", value: "500")]
        if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        do {
            return try decode(HistoryPage.self, try await get("history", query: query, cost: 2))
        } catch let error as APIError where error.status == 404 {
            throw GmailError.historyExpired
        }
    }

    // MARK: Requests

    public struct APIError: LocalizedError, Sendable {
        public var status: Int
        public var message: String
        public init(status: Int, message: String) {
            self.status = status
            self.message = message
        }
        public var errorDescription: String? { "Gmail refused the request (\(status): \(message))." }
    }

    public enum GmailError: LocalizedError, Sendable {
        case historyExpired
        public var errorDescription: String? { "Gmail's change history doesn't go back that far." }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    func get(_ path: String, query: [URLQueryItem] = [], cost: Double) async throws -> Data {
        try await send("GET", url: Self.base.appendingPathComponent(path), query: query, cost: cost)
    }

    private func send(_ method: String, _ path: String, json: [String: Any], cost: Double) async throws -> Data {
        try await send(method, url: Self.base.appendingPathComponent(path), body: try JSONSerialization.data(withJSONObject: json),
                       contentType: "application/json", cost: cost)
    }

    /// Sends a request once the quota allows `cost` more units (see `QuotaGate`). A token Gmail no
    /// longer accepts is renewed once; rate limits and server errors are retried after a pause
    /// (growing each time, or as Gmail asks).
    private func send(
        _ method: String, url: URL, query: [URLQueryItem] = [], body: Data? = nil, contentType: String? = nil, cost: Double
    ) async throws -> Data {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var renewed = false
        var pause = 1.0
        while true {
            await quota.spend(cost)
            var request = URLRequest(url: components.url!)
            request.httpMethod = method
            request.httpBody = body
            if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            request.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if (200..<300).contains(status) { return data }
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = object?["error"] as? [String: Any]
            let reason = ((error?["errors"] as? [[String: Any]])?.first?["reason"] as? String) ?? ""
            if status == 401, !renewed {
                renewed = true
                await tokens.invalidate()
                continue
            }
            let limited = status == 429 || (status == 403 && reason.lowercased().contains("ratelimit"))
            #if DEBUG
                if ProcessInfo.processInfo.environment["MMJ_DEBUG_GMAIL"] != nil {
                    NSLog("MMJ gmail \(status) \(reason) \(method) \(url.lastPathComponent) — \(error?["message"] as? String ?? "")")
                }
            #endif
            if (limited || status >= 500), pause <= 64 {
                let asked = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                try await Task.sleep(for: .seconds(asked ?? pause))
                pause *= 2
                continue
            }
            let message = error?["message"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: status)
            throw APIError(status: status, message: message)
        }
    }
}

// MARK: - Message

extension GmailClient {
    public struct Message: Decodable, Sendable {
        public var id: String
        public var threadId: String?
        public var labelIds: [String]?
        public var snippet: String?
        public var historyId: String?
        /// When Gmail received it, in milliseconds since 1970 (as text).
        public var internalDate: String?
        public var sizeEstimate: Int?
        public var payload: Part?
        /// The whole message (format raw), base64url.
        public var raw: String?

        public var receivedAt: Date? { internalDate.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) } }
    }

    public struct Header: Decodable, Sendable {
        public var name: String
        public var value: String
    }

    public final class Part: Decodable, Sendable {
        public let partId: String?
        public let mimeType: String?
        public let filename: String?
        public let headers: [Header]?
        public let body: Body?
        public let parts: [Part]?

        public struct Body: Decodable, Sendable {
            public var size: Int?
            /// The part's content, transfer encoding removed, base64url (small parts in format full).
            public var data: String?
            public var attachmentId: String?
        }

        /// The first header named `name` (case ignored).
        public func header(_ name: String) -> String? {
            headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        /// Every header named `name`, in order.
        public func headers(_ name: String) -> [String] {
            (headers ?? []).filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
        }
    }
}

extension Data {
    /// Decodes base64url (RFC 4648 §5), with or without padding.
    public init?(base64URL text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 = base64.trimmingCharacters(in: .whitespacesAndNewlines)
        while base64.count % 4 != 0 { base64 += "=" }
        self.init(base64Encoded: base64)
    }
}

/// Paces one account's requests under Gmail's quota of 6,000 units a minute per account (a raw or
/// full message costs 60, its headers 20, a history page 2): a bucket refilled at 95 units a second
/// (5,700 a minute, some room for other apps on the account) that a request waits on when it's short,
/// rather than being refused and backing off.
actor QuotaGate {
    private let rate: Double
    private let capacity: Double
    private var available: Double
    private var updated = ContinuousClock.now

    init(unitsPerSecond rate: Double = 95, burst capacity: Double = 600) {
        self.rate = rate
        self.capacity = capacity
        self.available = capacity
    }

    func spend(_ cost: Double) async {
        let now = ContinuousClock.now
        let elapsed = now - updated
        available = min(capacity, available + rate * (Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18))
        updated = now
        // Reserved at once (the balance may go below zero), then waited out: requests leave in order,
        // each as soon as its share has built up.
        let shortfall = cost - available
        available -= cost
        if shortfall > 0 { try? await Task.sleep(for: .seconds(shortfall / rate)) }
    }
}
