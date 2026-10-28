import Foundation

public enum Capability {
    public static let core = "urn:ietf:params:jmap:core"
    public static let mail = "urn:ietf:params:jmap:mail"
    public static let submission = "urn:ietf:params:jmap:submission"
    /// RFC 8887: JMAP over WebSocket, including push.
    public static let webSocket = "urn:ietf:params:jmap:websocket"
    /// RFC 9404: Blob/get can return several blobs' contents in one request.
    public static let blob = "urn:ietf:params:jmap:blob"
}

/// Identifies one method call inside a request, so its response can be looked up
/// and later calls can reference its result.
public struct CallID: Sendable, Hashable {
    public let id: String
    public let name: String
}

/// A JMAP API request (RFC 8620 §3.3): several method calls sent in one HTTP round trip.
public struct JMAPRequest: Sendable {
    public var using: [String]
    public private(set) var methodCalls: [(name: String, arguments: [String: JSONValue], id: String)] = []

    public init(using: [String] = [Capability.core, Capability.mail]) {
        self.using = using
    }

    @discardableResult
    public mutating func call(_ name: String, _ arguments: [String: JSONValue]) -> CallID {
        let id = "c\(methodCalls.count)"
        methodCalls.append((name, arguments, id))
        return CallID(id: id, name: name)
    }

    /// A result reference (RFC 8620 §3.7). Use it under a key prefixed with `#`,
    /// e.g. `["#ids": JMAPRequest.ref(query, "/ids")]`.
    public static func ref(_ call: CallID, _ path: String) -> JSONValue {
        ["resultOf": .string(call.id), "name": .string(call.name), "path": .string(path)]
    }

    public func encoded() throws -> Data {
        let calls: [JSONValue] = methodCalls.map { .array([.string($0.name), .object($0.arguments), .string($0.id)]) }
        let body: JSONValue = ["using": .strings(using), "methodCalls": .array(calls)]
        return try JMAPCoding.encoder.encode(body)
    }
}

/// A method-level error (RFC 8620 §3.6.2), e.g. `cannotCalculateChanges`.
public struct JMAPMethodError: Error, Sendable, CustomStringConvertible {
    public let type: String
    public let detail: String?
    public let method: String

    public var description: String { "\(method) failed: \(type)\(detail.map { " — \($0)" } ?? "")" }
}

/// A JMAP API response: its method responses' names and call ids, read in one quick pass; each call's
/// arguments are decoded when asked for, straight into their type (one pass over the response, the
/// other calls skipped), not into a JSON tree first.
public struct JMAPResponse: Sendable {
    /// Each method response's name and call id, in order.
    public let calls: [(name: String, id: String)]
    public let sessionState: String?
    private let data: Data

    public init(data: Data) throws {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw JMAPError.invalidResponse("malformed response: \(error)")
        }
        guard let responses = envelope.methodResponses else { throw JMAPError.invalidResponse("missing methodResponses") }
        calls = responses.map { ($0.name, $0.id) }
        sessionState = envelope.sessionState
        self.data = data
    }

    /// Returns the arguments of the response to `call`, throwing if the server returned an error for it.
    public func arguments(_ call: CallID) throws -> JSONValue {
        try decode(JSONValue.self, call)
    }

    /// The arguments of the response to `call` as `T`, throwing if the server returned an error for it.
    public func decode<T: Decodable>(_ type: T.Type, _ call: CallID) throws -> T {
        if let error = calls.firstIndex(where: { $0.id == call.id && $0.name == "error" }) {
            let details = try arguments(at: error, as: MethodErrorArguments.self)
            throw JMAPMethodError(type: details.type ?? "unknown", detail: details.description, method: call.name)
        }
        guard let index = calls.firstIndex(where: { $0.id == call.id && $0.name == call.name }) else {
            throw JMAPError.invalidResponse("no response for \(call.name) (\(call.id))")
        }
        return try arguments(at: index, as: T.self)
    }

    private func arguments<T: Decodable>(at index: Int, as type: T.Type) throws -> T {
        let decoder = JMAPCoding.decoder
        decoder.userInfo[ResponseCoding.index] = index
        return try decoder.decode(Arguments<T>.self, from: data).value
    }

    /// The response without its calls' arguments.
    private struct Envelope: Decodable {
        struct Call: Decodable {
            let name: String
            let id: String

            init(from decoder: Decoder) throws {
                var parts = try decoder.unkeyedContainer()
                name = try parts.decode(String.self)
                _ = try parts.decode(Skipped.self)
                id = try parts.decode(String.self)
            }
        }

        let methodResponses: [Call]?
        let sessionState: String?
    }

    /// The arguments of the method response at `ResponseCoding.index`, the others skipped.
    private struct Arguments<T: Decodable>: Decodable {
        let value: T

        enum Keys: String, CodingKey { case methodResponses }

        init(from decoder: Decoder) throws {
            let wanted = decoder.userInfo[ResponseCoding.index] as? Int ?? 0
            var list = try decoder.container(keyedBy: Keys.self).nestedUnkeyedContainer(forKey: .methodResponses)
            while !list.isAtEnd {
                let index = list.currentIndex
                guard index == wanted else {
                    _ = try list.decode(Skipped.self)
                    continue
                }
                var call = try list.nestedUnkeyedContainer()
                _ = try call.decode(Skipped.self)  // its name
                value = try call.decode(T.self)
                return
            }
            throw JMAPError.invalidResponse("missing method response \(wanted)")
        }
    }

    private struct MethodErrorArguments: Decodable {
        let type: String?
        let description: String?
    }
}

private enum ResponseCoding {
    static let index = CodingUserInfoKey(rawValue: "JMAPResponse.index")!
}

/// Any JSON value, read past.
private struct Skipped: Decodable {
    init(from decoder: Decoder) throws {}
}

public enum JMAPError: Error, Sendable, CustomStringConvertible {
    case unauthorized
    case http(status: Int, body: String, url: URL? = nil)
    case invalidResponse(String)
    case missingCapability(String)

    public var description: String {
        switch self {
        case .unauthorized: "Authentication failed (check username and password or token)"
        case .http(let status, let body, let url):
            "HTTP \(status) from \(url?.absoluteString ?? "server"): \(body.prefix(500))"
        case .invalidResponse(let why): "Invalid JMAP response: \(why)"
        case .missingCapability(let cap): "Server does not support \(cap)"
        }
    }
}
