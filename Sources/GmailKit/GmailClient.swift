import Foundation

/// The Gmail API (https://developers.google.com/gmail/api) for one account, signed in with Google.
public struct GmailClient: Sendable {
    static let base = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/")!

    private let tokens: GoogleTokenSource
    private let session: URLSession

    public init(tokens: GoogleTokenSource, session: URLSession = .shared) {
        self.tokens = tokens
        self.session = session
    }

    public struct Profile: Decodable, Sendable {
        public var emailAddress: String
        public var messagesTotal: Int?
        public var historyId: String?
    }

    /// The account's address and mailbox size.
    public func profile() async throws -> Profile {
        try JSONDecoder().decode(Profile.self, from: try await get("profile"))
    }

    public struct APIError: LocalizedError, Sendable {
        public var status: Int
        public var message: String
        public var errorDescription: String? { "Gmail refused the request (\(status): \(message))." }
    }

    /// GETs `path` (relative to the account), retrying once with a new access token if Gmail says the
    /// one used ran out.
    func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        var components = URLComponents(url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        for attempt in 0..<2 {
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, attempt == 0 {
                await tokens.invalidate()
                continue
            }
            guard (200..<300).contains(status) else {
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let message = (object?["error"] as? [String: Any])?["message"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: status)
                throw APIError(status: status, message: message)
            }
            return data
        }
        throw APIError(status: 401, message: "Not signed in")
    }
}
