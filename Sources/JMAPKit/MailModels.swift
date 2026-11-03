import Foundation

// Typed models for the subset of RFC 8621 (JMAP Mail) the client uses.

public struct Mailbox: Decodable, Sendable {
    public let id: String
    public let name: String
    public let parentId: String?
    public let role: String?
    public let sortOrder: Int?
    public let totalEmails: Int?
    public let unreadEmails: Int?
    public let isSubscribed: Bool?
}

public struct EmailAddress: Codable, Sendable, Hashable {
    public let name: String?
    public let email: String?

    public init(name: String?, email: String?) {
        self.name = name
        self.email = email
    }
}

/// A group in an address header ("undisclosed-recipients:;" is one with no members).
public struct EmailAddressGroup: Decodable, Sendable {
    public let name: String?
    public let addresses: [EmailAddress]
}

public struct Email: Decodable, Sendable {
    public let id: String
    public let blobId: String
    public let threadId: String
    public let mailboxIds: [String: Bool]
    public let keywords: [String: Bool]
    public let size: Int
    public let receivedAt: Date
    public let messageId: [String]?
    public let inReplyTo: [String]?
    public let references: [String]?
    public let sender: [EmailAddress]?
    public let from: [EmailAddress]?
    public let to: [EmailAddress]?
    public let cc: [EmailAddress]?
    public let bcc: [EmailAddress]?
    public let replyTo: [EmailAddress]?
    /// To and Cc with their groups, whose names `to` and `cc` leave out.
    public let toGroups: [EmailAddressGroup]?
    public let ccGroups: [EmailAddressGroup]?
    public let subject: String?
    public let sentAt: Date?
    /// The Date header as written (" Mon, 26 Oct 2026 09:27:08 +0200"), for the sender's time zone.
    /// Raw: the Text form is only allowed for unstructured headers (RFC 8621 §4.1.2), and Fastmail
    /// refuses the whole request over it.
    public let dateHeader: String?
    public let hasAttachment: Bool
    public let preview: String?

    /// The properties to request so the response decodes into `Email`.
    public static let properties: [String] = [
        "id", "blobId", "threadId", "mailboxIds", "keywords", "size", "receivedAt",
        "messageId", "inReplyTo", "references", "sender", "from", "to", "cc", "bcc", "replyTo",
        "subject", "sentAt", "hasAttachment", "preview", groupedTo, groupedCc, dateHeaderProperty,
    ]
    public static let dateHeaderProperty = "header:Date:asRaw"
    public static let groupedTo = "header:To:asGroupedAddresses"
    public static let groupedCc = "header:Cc:asGroupedAddresses"

    enum CodingKeys: String, CodingKey {
        case id, blobId, threadId, mailboxIds, keywords, size, receivedAt, messageId, inReplyTo, references
        case sender, from, to, cc, bcc, replyTo, subject, sentAt, hasAttachment, preview
        case toGroups = "header:To:asGroupedAddresses", ccGroups = "header:Cc:asGroupedAddresses"
        case dateHeader = "header:Date:asRaw"
    }
}

public struct EmailBodyPart: Decodable, Sendable {
    public let partId: String?
    public let blobId: String?
    public let size: Int?
    public let type: String
    public let charset: String?
    public let name: String?
    public let disposition: String?
    public let cid: String?
}

public struct EmailBodyValue: Decodable, Sendable {
    public let value: String
    public let isEncodingProblem: Bool?
    public let isTruncated: Bool?
}

/// The body-related properties of an Email, fetched lazily when a message is opened.
public struct EmailBody: Decodable, Sendable {
    public let id: String
    public let textBody: [EmailBodyPart]
    public let htmlBody: [EmailBodyPart]
    public let attachments: [EmailBodyPart]
    public let bodyValues: [String: EmailBodyValue]

    public static let properties = ["id", "textBody", "htmlBody", "attachments", "bodyValues"]
}

public struct Identity: Decodable, Sendable {
    public let id: String
    public let name: String
    public let email: String
    public let textSignature: String?
    public let htmlSignature: String?
}

public struct GetResponse<T: Decodable & Sendable>: Decodable, Sendable {
    public let accountId: String
    public let state: String
    public let list: [T]
    public let notFound: [String]?
}

public struct ChangesResponse: Decodable, Sendable {
    public let accountId: String
    public let oldState: String
    public let newState: String
    public let hasMoreChanges: Bool
    public let created: [String]
    public let updated: [String]
    public let destroyed: [String]
}

public struct QueryResponse: Decodable, Sendable {
    public let accountId: String
    public let queryState: String
    public let ids: [String]
    public let position: Int
    public let total: Int?
}

/// One item of a Blob/get response (RFC 9404) asked for `data:asBase64`.
public struct BlobData: Decodable, Sendable {
    public let id: String
    public let base64: String?
    public let isEncodingProblem: Bool?
    public let isTruncated: Bool?

    enum CodingKeys: String, CodingKey {
        case id, isEncodingProblem, isTruncated
        case base64 = "data:asBase64"
    }

    public var data: Data? { base64.flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) } }
}

/// A Blob/get response. Unlike other /get responses it need not carry a `state`.
public struct BlobGetResponse: Decodable, Sendable {
    public let list: [BlobData]
    public let notFound: [String]?
}

/// A push StateChange (RFC 8620 §7.1): accountId → (type → new state).
public struct StateChange: Decodable, Sendable {
    public let changed: [String: [String: String]]
}
