import Foundation

public enum Capability {
    public static let core = "urn:ietf:params:jmap:core"
    public static let mail = "urn:ietf:params:jmap:mail"
    public static let submission = "urn:ietf:params:jmap:submission"
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

public struct JMAPResponse: Sendable {
    public struct Invocation: Sendable {
        public let name: String
        public let arguments: JSONValue
        public let id: String
    }

    public let invocations: [Invocation]
    public let sessionState: String?

    public init(data: Data) throws {
        let raw = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .array(let responses)? = raw["methodResponses"] else {
            throw JMAPError.invalidResponse("missing methodResponses")
        }
        invocations = try responses.map { item in
            guard case .array(let parts) = item, parts.count == 3,
                let name = parts[0].stringValue, let id = parts[2].stringValue
            else { throw JMAPError.invalidResponse("malformed invocation") }
            return Invocation(name: name, arguments: parts[1], id: id)
        }
        sessionState = raw["sessionState"]?.stringValue
    }

    /// Returns the arguments of the response to `call`, throwing if the server returned an error for it.
    public func arguments(_ call: CallID) throws -> JSONValue {
        let matching = invocations.filter { $0.id == call.id }
        if let error = matching.first(where: { $0.name == "error" }) {
            throw JMAPMethodError(
                type: error.arguments["type"]?.stringValue ?? "unknown",
                detail: error.arguments["description"]?.stringValue,
                method: call.name)
        }
        guard let invocation = matching.first(where: { $0.name == call.name }) else {
            throw JMAPError.invalidResponse("no response for \(call.name) (\(call.id))")
        }
        return invocation.arguments
    }

    public func decode<T: Decodable>(_ type: T.Type, _ call: CallID) throws -> T {
        try arguments(call).decode(T.self)
    }
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
