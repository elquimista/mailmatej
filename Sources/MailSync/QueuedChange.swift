import Foundation
import JMAPKit

/// A change to make on an account's server, kept in the store's change queue while the server can't be
/// reached, and made in order once it can (see `SyncCoordinator`).
enum QueuedChange: Codable, Sendable {
    /// Email/set update: the same patch on every message.
    case update(remoteIds: [String], patch: [String: JSONValue])
    /// Email/set destroy.
    case destroy(remoteIds: [String])
    /// A move to another account: the raw message (stored locally) is imported there, then the original
    /// is deleted.
    case moveAcross(
        remoteId: String, blobId: String, targetAccountId: String, mailboxRemoteId: String, keywords: [String],
        receivedAt: Date)
}
