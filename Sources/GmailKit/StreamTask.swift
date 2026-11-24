import Foundation

/// Reads and writes on a `URLSessionStreamTask` that resume their caller once. CFNetwork calls a read's
/// completion handler a second time when the read has timed out and the connection then fails (a TLS
/// handshake that never finishes on a bad network, then a hang-up: tested), which Swift's own async
/// versions of these calls take for a fatal misuse ("continuation resumed more than once").
extension URLSessionStreamTask {
    func readOnce(minLength: Int, maxLength: Int, timeout: TimeInterval) async throws -> (data: Data?, atEnd: Bool) {
        let once = Once()
        return try await withCheckedThrowingContinuation { continuation in
            readData(ofMinLength: minLength, maxLength: maxLength, timeout: timeout) { data, atEnd, error in
                guard once.first() else { return }
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: (data, atEnd)) }
            }
        }
    }

    func writeOnce(_ data: Data, timeout: TimeInterval) async throws {
        let once = Once()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            write(data, timeout: timeout) { error in
                guard once.first() else { return }
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}

/// True the first time only.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func first() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}
