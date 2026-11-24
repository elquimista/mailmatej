import Foundation
import Network
import Testing

@testable import GmailKit

/// A connection on a bad network: the greeting doesn't come in time, then the server hangs up. CFNetwork
/// answers the timed-out read a second time, and uses a dropped task it's still connecting; either
/// crashed the app (1.21.1, on Gmail IMAP). Here the test process would crash.
@Suite struct StreamTaskTests {
    @Test func imapGreetingTimesOutThenTheServerHangsUp() async throws {
        let server = try await StallingServer(hangUpAfter: 1.5)
        var kept: [IMAPConnection] = []
        for i in 0..<6 {
            let connection = IMAPConnection(host: "127.0.0.1", port: server.port)
            try await connection.open()
            await #expect(throws: GmailIMAP.IMAPError.self) { try await connection.readResponse(timeout: 0.3) }
            if i.isMultiple(of: 2) { kept.append(connection) }  // the others are dropped while connecting
        }
        try await Task.sleep(for: .seconds(2.5))  // past the hang-up
        #expect(kept.count == 3)
    }

    @Test func smtpGreetingTimesOutThenTheServerHangsUp() async throws {
        let server = try await StallingServer(hangUpAfter: 1.5)
        var kept: [SMTPConnection] = []
        for i in 0..<6 {
            let connection = SMTPConnection(host: "127.0.0.1", port: server.port, timeout: 0.3)
            connection.open()
            await #expect(throws: GmailSMTP.SMTPError.self) { _ = try await connection.reply() }
            if i.isMultiple(of: 2) { kept.append(connection) }
        }
        try await Task.sleep(for: .seconds(2.5))
        #expect(kept.count == 3)
    }
}

/// Takes TCP connections on localhost, never answers (so TLS never finishes), and hangs up after a while.
private final class StallingServer: @unchecked Sendable {
    private let listener: NWListener
    let port: Int

    init(hangUpAfter delay: Double) async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        let queue = DispatchQueue(label: "StallingServer")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + delay) { connection.cancel() }  // holds it till then
        }
        port = try await withCheckedThrowingContinuation { continuation in
            let resumed = Resumed()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if resumed.first() { continuation.resume(returning: Int(listener.port!.rawValue)) }
                case .failed(let error): if resumed.first() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    deinit { listener.cancel() }
}

private final class Resumed: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func first() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}
