import Foundation

/// Raw RFC 5322 messages on disk: `Messages/<accountId>/<xx>/<blobId>.eml`.
public struct BlobStore: Sendable {
    public let root: URL

    public func url(accountId: String, blobId: String) -> URL {
        let safe = blobId.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? String($0) : "_" }.joined()
        return root.appendingPathComponent(accountId, isDirectory: true)
            .appendingPathComponent(String(safe.suffix(2)), isDirectory: true)
            .appendingPathComponent(safe + ".eml")
    }

    /// Cached MIME parts (e.g. embedded images): `Messages/<accountId>/parts/<xx>/<blobId>`.
    public func partURL(accountId: String, blobId: String) -> URL {
        let message = url(accountId: accountId, blobId: blobId)
        return root.appendingPathComponent(accountId, isDirectory: true)
            .appendingPathComponent("parts", isDirectory: true)
            .appendingPathComponent(message.deletingLastPathComponent().lastPathComponent, isDirectory: true)
            .appendingPathComponent(message.deletingPathExtension().lastPathComponent)
    }

    public func readPart(accountId: String, blobId: String) -> Data? {
        try? Data(contentsOf: partURL(accountId: accountId, blobId: blobId))
    }

    public func writePart(_ data: Data, accountId: String, blobId: String) throws {
        let target = partURL(accountId: accountId, blobId: blobId)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }

    public func contains(accountId: String, blobId: String) -> Bool {
        FileManager.default.fileExists(atPath: url(accountId: accountId, blobId: blobId).path)
    }

    public func write(_ data: Data, accountId: String, blobId: String) throws {
        let target = url(accountId: accountId, blobId: blobId)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }

    public func read(accountId: String, blobId: String) -> Data? {
        try? Data(contentsOf: url(accountId: accountId, blobId: blobId))
    }

    public func removeAll(accountId: String) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(accountId, isDirectory: true))
    }
}
