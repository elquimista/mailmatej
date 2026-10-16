import Foundation

/// The JMAP Session resource (RFC 8620 §2).
public struct Session: Decodable, Sendable {
    public struct Account: Decodable, Sendable {
        public let name: String
        public let isPersonal: Bool
        public let isReadOnly: Bool
        public let accountCapabilities: [String: JSONValue]
    }

    public let capabilities: [String: JSONValue]
    public let accounts: [String: Account]
    public let primaryAccounts: [String: String]
    public let username: String
    public internal(set) var apiUrl: URL
    public internal(set) var downloadUrl: String
    public internal(set) var uploadUrl: String
    public internal(set) var eventSourceUrl: String
    public let state: String

    /// Moves the advertised endpoints onto `origin` (scheme, host, port), keeping their paths.
    /// Used for servers reached on loopback (a local dev server) that advertise their public hostname.
    func rebased(onto origin: URL) -> Session {
        func rebase(_ string: String) -> String {
            guard var c = URLComponents(string: string.replacingOccurrences(of: "{", with: "%7B")
                .replacingOccurrences(of: "}", with: "%7D"))
            else { return string }
            c.scheme = origin.scheme
            c.host = origin.host
            c.port = origin.port
            return (c.string ?? string).replacingOccurrences(of: "%7B", with: "{")
                .replacingOccurrences(of: "%7D", with: "}")
        }
        var s = self
        s.apiUrl = URL(string: rebase(apiUrl.absoluteString)) ?? apiUrl
        s.downloadUrl = rebase(downloadUrl)
        s.uploadUrl = rebase(uploadUrl)
        s.eventSourceUrl = rebase(eventSourceUrl)
        return s
    }

    public var maxObjectsInGet: Int { capabilities[Capability.core]?["maxObjectsInGet"]?.intValue ?? 500 }
    public var maxCallsInRequest: Int { capabilities[Capability.core]?["maxCallsInRequest"]?.intValue ?? 16 }

    public var primaryMailAccountId: String? { primaryAccounts[Capability.mail] }

    public func supports(_ capability: String) -> Bool { capabilities[capability] != nil }

    public func downloadURL(accountId: String, blobId: String, type: String, name: String) -> URL? {
        URL(string: Self.expand(downloadUrl, [
            "accountId": accountId, "blobId": blobId, "type": type, "name": name,
        ]))
    }

    public func eventSourceURL(types: String = "*", closeAfter: String = "no", ping: Int = 30) -> URL? {
        URL(string: Self.expand(eventSourceUrl, [
            "types": types, "closeafter": closeAfter, "ping": String(ping),
        ]))
    }

    /// Expands RFC 6570 level-1 templates (`{name}`), which is all RFC 8620 requires.
    /// Also tolerates the `{?a,b}` form some servers use for the query part.
    static func expand(_ template: String, _ values: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }

        var result = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            result += rest[..<open]
            let expr = rest[rest.index(after: open)..<close]
            if expr.hasPrefix("?") {
                let names = expr.dropFirst().split(separator: ",").map(String.init)
                let pairs = names.compactMap { n in values[n].map { "\(n)=\(enc($0))" } }
                if !pairs.isEmpty { result += "?" + pairs.joined(separator: "&") }
            } else {
                result += enc(values[String(expr)] ?? "")
            }
            rest = rest[rest.index(after: close)...]
        }
        return result + rest
    }
}
