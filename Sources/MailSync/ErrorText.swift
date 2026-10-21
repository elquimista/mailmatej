import Foundation
import JMAPKit

/// Turns errors from networking, JMAP and the store into sentences a user can act on.
/// The raw description stays available (`technical`) for debug builds and logs.
public enum ErrorText {
    public static func friendly(_ error: Error) -> String {
        if let urlError = error as? URLError { return friendly(urlError) }
        if let jmap = error as? JMAPError { return friendly(jmap) }
        if let method = error as? JMAPMethodError {
            return "The server refused the request (\(method.type))."
        }
        if error is DecodingError {
            return "The server’s reply wasn’t valid JMAP. Check that the address points to a JMAP server."
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return friendly(URLError(URLError.Code(rawValue: ns.code))) }
        return ns.localizedDescription
    }

    public static func technical(_ error: Error) -> String { String(describing: error) }

    /// Whether the server couldn't be reached at all (offline, connection lost, timed out, server
    /// temporarily unavailable), so the same request may work later, as opposed to being refused.
    public static func isUnreachable(_ error: Error) -> Bool {
        if case JMAPError.http(let status, _, _) = error { return [502, 503, 504].contains(status) }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        let codes: [URLError.Code] = [
            .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost,
            .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive,
        ]
        return codes.map(\.rawValue).contains(ns.code)
    }

    /// The human-readable part of an RFC 7807 problem body (`detail`, else `title`), as JMAP servers send.
    static func problemDetail(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let text = (json["detail"] as? String) ?? (json["title"] as? String)
        return text.map { $0.hasSuffix(".") ? $0 : $0 + "." }
    }

    private static func friendly(_ error: URLError) -> String {
        let host = error.failingURL?.host.map { "“\($0)”" } ?? "the server"
        switch error.code {
        case .cannotFindHost, .dnsLookupFailed:
            return "Couldn’t find \(host). Check the server address."
        case .cannotConnectToHost:
            return "Couldn’t connect to \(host). The server may be down or not accepting connections."
        case .notConnectedToInternet:
            return "You’re offline. Check your internet connection."
        case .timedOut:
            return "\(host.prefix(1).uppercased() + host.dropFirst()) took too long to respond."
        case .networkConnectionLost:
            return "The connection to \(host) was lost."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
            .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return "Couldn’t make a secure connection to \(host). Its certificate may be invalid or expired."
        case .badURL, .unsupportedURL:
            return "That server address isn’t valid."
        case .appTransportSecurityRequiresSecureConnection:
            return "\(host.prefix(1).uppercased() + host.dropFirst()) only offers an insecure (http) connection. Use an https address."
        default:
            return "Couldn’t reach \(host) (\(error.localizedDescription))."
        }
    }

    private static func friendly(_ error: JMAPError) -> String {
        switch error {
        case .unauthorized:
            return "The server rejected the sign-in. Check the username and password, or the API token."
        case .http(404, _, _):
            return "No JMAP service was found at that address. Try the full session URL, e.g. https://mail.example.com/jmap/session."
        case .http(let status, _, _) where status >= 500:
            return "The server had a problem (HTTP \(status)). Try again later."
        case .http(let status, let body, _):
            if let reason = problemDetail(body) {
                return "The server rejected the request (HTTP \(status)): \(reason)"
            }
            return "The server returned an error (HTTP \(status))."
        case .invalidResponse:
            return "The server’s reply wasn’t valid JMAP. Check that the address points to a JMAP server."
        case .missingCapability:
            return "This server supports JMAP but not JMAP Mail."
        }
    }
}
