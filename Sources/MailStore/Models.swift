import Foundation
import GRDB

public struct AccountRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Hashable {
    public static let databaseTableName = "account"

    public enum AuthKind: String, Codable, Sendable { case basic, bearer }

    public var id: String
    public var name: String
    public var kind: String
    public var sessionURL: String
    public var username: String
    public var authKind: AuthKind
    public var remoteAccountId: String?
    public var sortOrder: Int
    public var isEnabled: Bool
    /// The sender name for this account's mail, where the server's identity has none.
    public var fullName: String
    /// The user's own addresses on this account, comma-separated (besides the server's identities).
    public var emailAddresses: String

    public init(
        id: String = UUID().uuidString, name: String, kind: String = "jmap", sessionURL: String,
        username: String, authKind: AuthKind, remoteAccountId: String? = nil, sortOrder: Int = 0,
        isEnabled: Bool = true, fullName: String = "", emailAddresses: String = ""
    ) {
        self.fullName = fullName
        self.emailAddresses = emailAddresses
        self.id = id
        self.name = name
        self.kind = kind
        self.sessionURL = sessionURL
        self.username = username
        self.authKind = authKind
        self.remoteAccountId = remoteAccountId
        self.sortOrder = sortOrder
        self.isEnabled = isEnabled
    }
}

public struct MailboxRecord: Codable, FetchableRecord, Sendable, Hashable {
    public var id: Int64
    public var accountId: String
    public var remoteId: String
    public var parentRemoteId: String?
    public var name: String
    public var role: String?
    public var sortOrder: Int
    public var totalEmails: Int
    public var unreadEmails: Int
}

public enum AddressRole: Int, Sendable, CaseIterable {
    case from = 0, sender, to, cc, bcc, replyTo
}

/// Protocol-neutral input for upserting a message. JMAP and (later) IMAP sync both map into this.
public struct IncomingMessage: Sendable {
    public struct Address: Sendable {
        public var role: AddressRole
        public var name: String?
        public var email: String

        public init(role: AddressRole, name: String?, email: String) {
            self.role = role
            self.name = name
            self.email = email
        }
    }

    public var remoteId: String
    public var threadId: String
    public var blobId: String
    public var mailboxRemoteIds: [String]
    public var keywords: [String]
    public var size: Int
    public var receivedAt: Date
    public var sentAt: Date?
    public var messageIdHeader: String?
    public var inReplyTo: String?
    public var subject: String
    public var preview: String
    public var hasAttachment: Bool
    public var addresses: [Address]

    public init(
        remoteId: String, threadId: String, blobId: String, mailboxRemoteIds: [String], keywords: [String],
        size: Int, receivedAt: Date, sentAt: Date?, messageIdHeader: String?, inReplyTo: String?,
        subject: String, preview: String, hasAttachment: Bool, addresses: [Address]
    ) {
        self.remoteId = remoteId
        self.threadId = threadId
        self.blobId = blobId
        self.mailboxRemoteIds = mailboxRemoteIds
        self.keywords = keywords
        self.size = size
        self.receivedAt = receivedAt
        self.sentAt = sentAt
        self.messageIdHeader = messageIdHeader
        self.inReplyTo = inReplyTo
        self.subject = subject
        self.preview = preview
        self.hasAttachment = hasAttachment
        self.addresses = addresses
    }
}

public struct IncomingMailbox: Sendable {
    public var remoteId: String
    public var parentRemoteId: String?
    public var name: String
    public var role: String?
    public var sortOrder: Int
    public var totalEmails: Int
    public var unreadEmails: Int

    public init(
        remoteId: String, parentRemoteId: String?, name: String, role: String?, sortOrder: Int,
        totalEmails: Int, unreadEmails: Int
    ) {
        self.remoteId = remoteId
        self.parentRemoteId = parentRemoteId
        self.name = name
        self.role = role
        self.sortOrder = sortOrder
        self.totalEmails = totalEmails
        self.unreadEmails = unreadEmails
    }
}

/// What a message list shows for one row. Fetched lazily for visible rows only.
public struct MessageRow: FetchableRecord, Sendable {
    public var id: Int64
    public var accountId: String
    public var fromDisplay: String
    public var fromEmail: String
    public var subject: String
    public var receivedAt: Date
    public var isSeen: Bool
    public var isFlagged: Bool
    public var isAnswered: Bool
    public var hasAttachment: Bool
    public var size: Int
    public var mailboxName: String
    public var accountName: String

    public init(row: Row) {
        id = row["id"]
        accountId = row["accountId"]
        fromDisplay = row["fromDisplay"]
        fromEmail = row["fromEmail"]
        subject = row["subject"]
        receivedAt = Date(timeIntervalSince1970: row["receivedAt"])
        isSeen = row["isSeen"]
        isFlagged = row["isFlagged"]
        isAnswered = row["isAnswered"]
        hasAttachment = row["hasAttachment"]
        size = row["size"]
        mailboxName = row["mailboxName"] ?? ""
        accountName = row["accountName"] ?? ""
    }
}

/// Everything the message view needs besides the body.
/// A sending identity (JMAP Identity) of an account.
public struct IdentityRecord: Sendable, Hashable {
    public var accountId: String
    public var remoteId: String
    public var name: String
    /// Lowercased.
    public var email: String

    public init(accountId: String, remoteId: String, name: String, email: String) {
        self.accountId = accountId
        self.remoteId = remoteId
        self.name = name
        self.email = email
    }
}

public struct MessageDetail: Sendable {
    public var id: Int64
    public var accountId: String
    public var remoteId: String
    public var blobId: String
    public var subject: String
    public var receivedAt: Date
    public var sentAt: Date?
    public var addresses: [IncomingMessage.Address]

    public func addresses(_ role: AddressRole) -> [IncomingMessage.Address] { addresses.filter { $0.role == role } }
}

public struct MessageBody: Sendable {
    public var html: String?
    public var text: String?

    public init(html: String?, text: String?) {
        self.html = html
        self.text = text
    }
}

/// A MIME part of a message that can be fetched on its own (an embedded image, an attachment).
public struct MessagePart: Sendable, Hashable {
    public var blobId: String
    public var cid: String?
    public var type: String
    public var name: String?
    public var size: Int?

    public init(blobId: String, cid: String?, type: String, name: String?, size: Int?) {
        self.blobId = blobId
        self.cid = cid
        self.type = type
        self.name = name
        self.size = size
    }

    /// Content-IDs are compared without angle brackets and case-insensitively.
    public static func normalizeCID(_ cid: String) -> String {
        cid.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")).lowercased()
    }
}

/// Which messages a list shows.
public enum MessageScope: Hashable, Sendable {
    /// Everything except Trash and Junk, across all accounts.
    case allMessages
    /// Unified mailbox by JMAP role ("inbox", "sent", "archive", ...), across all accounts.
    case role(String)
    case flagged
    case mailbox(Int64)
    case account(String)
    /// Submailboxes of Flagged and All Messages: flagged mail in one mailbox or account, and one
    /// account's mail outside Trash and Junk.
    case flaggedInMailbox(Int64)
    case flaggedInAccount(String)
    case allInAccount(String)

    /// A stable string form, for settings: "all", "flagged", "role:inbox", "mailbox:42", "account:<id>",
    /// "flagged:mailbox:42", "flagged:account:<id>", "all:account:<id>".
    public var key: String {
        switch self {
        case .allMessages: "all"
        case .flagged: "flagged"
        case .role(let role): "role:\(role)"
        case .mailbox(let id): "mailbox:\(id)"
        case .account(let id): "account:\(id)"
        case .flaggedInMailbox(let id): "flagged:mailbox:\(id)"
        case .flaggedInAccount(let id): "flagged:account:\(id)"
        case .allInAccount(let id): "all:account:\(id)"
        }
    }

    public init?(key: String) {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        switch (parts.first, parts.count) {
        case ("all", 1): self = .allMessages
        case ("flagged", 1): self = .flagged
        case ("role", 2): self = .role(parts[1])
        case ("mailbox", 2): if let id = Int64(parts[1]) { self = .mailbox(id) } else { return nil }
        case ("account", 2): self = .account(parts[1])
        case ("flagged", 2), ("all", 2):
            let rest = parts[1].split(separator: ":", maxSplits: 1).map(String.init)
            guard rest.count == 2 else { return nil }
            switch (parts[0], rest[0]) {
            case ("flagged", "mailbox"): if let id = Int64(rest[1]) { self = .flaggedInMailbox(id) } else { return nil }
            case ("flagged", "account"): self = .flaggedInAccount(rest[1])
            case ("all", "account"): self = .allInAccount(rest[1])
            default: return nil
            }
        default: return nil
        }
    }
}

/// What a counter counts within a list (MailMate's "Count" choices that apply to received mail).
public enum MessageCount: Hashable, Sendable {
    case all
    case unread
    case flagged
    /// Not answered (no `$answered`), drafts excluded.
    case unreplied
}

public struct MessageSort: Hashable, Sendable {
    public enum Key: String, Sendable { case receivedAt, from, subject, size }
    public var key: Key
    public var ascending: Bool

    public init(key: Key, ascending: Bool) {
        self.key = key
        self.ascending = ascending
    }

    public static let newestFirst = MessageSort(key: .receivedAt, ascending: false)
}
