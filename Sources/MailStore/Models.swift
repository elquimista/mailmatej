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

    public init(
        id: String = UUID().uuidString, name: String, kind: String = "jmap", sessionURL: String,
        username: String, authKind: AuthKind, remoteAccountId: String? = nil, sortOrder: Int = 0,
        isEnabled: Bool = true
    ) {
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

/// Which messages a list shows.
public enum MessageScope: Hashable, Sendable {
    /// Everything except Trash and Junk, across all accounts.
    case allMessages
    /// Unified mailbox by JMAP role ("inbox", "sent", "archive", ...), across all accounts.
    case role(String)
    case flagged
    case mailbox(Int64)
    case account(String)
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
