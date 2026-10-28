import Foundation
import zlib

/// Raw RFC 5322 messages on disk, gzip-compressed: `Messages/<accountId>/<xx>/<blobId>.eml.gz` (Archive
/// Utility, or any gzip tool, opens them). Some stored before are plain `.eml` files.
public struct BlobStore: Sendable {
    public let root: URL

    /// A message's file, compressed.
    public func url(accountId: String, blobId: String) -> URL {
        plainURL(accountId: accountId, blobId: blobId).appendingPathExtension("gz")
    }

    /// A message's file as stored before messages were compressed.
    func plainURL(accountId: String, blobId: String) -> URL {
        let safe = blobId.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? String($0) : "_" }.joined()
        return root.appendingPathComponent(accountId, isDirectory: true)
            .appendingPathComponent(String(safe.suffix(2)), isDirectory: true)
            .appendingPathComponent(safe + ".eml")
    }

    /// Cached MIME parts (e.g. embedded images): `Messages/<accountId>/parts/<xx>/<blobId>`.
    public func partURL(accountId: String, blobId: String) -> URL {
        let message = plainURL(accountId: accountId, blobId: blobId)
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
            || FileManager.default.fileExists(atPath: plainURL(accountId: accountId, blobId: blobId).path)
    }

    public func write(_ data: Data, accountId: String, blobId: String) throws {
        let target = url(accountId: accountId, blobId: blobId)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Gzip.compress(data).write(to: target, options: .atomic)
        try? FileManager.default.removeItem(at: plainURL(accountId: accountId, blobId: blobId))  // one from before
    }

    public func read(accountId: String, blobId: String) -> Data? {
        let packed = url(accountId: accountId, blobId: blobId)
        if let data = try? Data(contentsOf: packed) { return Gzip.decompress(data) }
        if let data = try? Data(contentsOf: plainURL(accountId: accountId, blobId: blobId)) { return data }
        return (try? Data(contentsOf: packed)).flatMap(Gzip.decompress)  // compressed just now
    }

    /// Removes a message's file, either kind.
    public func remove(accountId: String, blobId: String) {
        try? FileManager.default.removeItem(at: url(accountId: accountId, blobId: blobId))
        try? FileManager.default.removeItem(at: plainURL(accountId: accountId, blobId: blobId))
    }

    public func removeAll(accountId: String) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(accountId, isDirectory: true))
    }
}

/// Gzip (RFC 1952), as the `gzip` tool writes it, through zlib.
enum Gzip {
    struct Failed: Error {}

    static func compress(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, MAX_WBITS + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION,
                            Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { throw Failed() }
        defer { deflateEnd(&stream) }
        var packed = Data(count: Int(deflateBound(&stream, uLong(data.count))))
        let status = data.withUnsafeBytes { input in
            packed.withUnsafeMutableBytes { output in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(output.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { throw Failed() }
        packed.count = Int(stream.total_out)
        return packed
    }

    static func decompress(_ data: Data) -> Data? {
        var stream = z_stream()
        guard inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var output = Data()
        if data.count >= 4 {  // the size it says it unpacks to (mod 4 GB): room for it at once
            output.reserveCapacity(data.suffix(4).reversed().reduce(0) { $0 << 8 | Int($1) })
        }
        var chunk = [UInt8](repeating: 0, count: 256 * 1024)
        let ended: Bool = data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            while true {
                let status = chunk.withUnsafeMutableBytes { buffer in
                    stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(buffer.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                output.append(contentsOf: chunk[..<(chunk.count - Int(stream.avail_out))])
                if status == Z_STREAM_END { return true }
                if status != Z_OK { return false }
            }
        }
        return ended ? output : nil
    }
}
