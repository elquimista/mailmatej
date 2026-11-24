import Foundation

/// Gmail's SMTP server (smtp.gmail.com, TLS on 465), signed in with the same Google token as the API
/// (XOAUTH2), for what the API can't do: deliver a message as it is to addresses that aren't in it (a
/// rule's Redirect). The API only ever sends to a message's own To, Cc and Bcc.
public actor GmailSMTP {
    public enum SMTPError: LocalizedError, Sendable {
        case signInRefused(String)
        case refused(code: Int, String)
        case closed

        public var errorDescription: String? {
            switch self {
            case .signInRefused(let why): "Gmail’s SMTP refused the sign-in (\(why))."
            case .refused(let code, let why): "Gmail’s SMTP refused the message (\(code) \(why))."
            case .closed: "Gmail’s SMTP connection closed."
            }
        }
    }

    private let email: String
    private let tokens: GoogleTokenSource
    private let host: String
    private let port: Int

    public init(email: String, tokens: GoogleTokenSource, host: String = "smtp.gmail.com", port: Int = 465) {
        self.email = email
        self.tokens = tokens
        self.host = host
        self.port = port
    }

    /// Delivers `message` (a whole raw message) to `recipients`, the envelope sender `mailFrom` (the
    /// account's address, or one it sends as). A token Gmail no longer accepts is renewed once.
    public func send(_ message: Data, from mailFrom: String, to recipients: [String]) async throws {
        do {
            try await attempt(message, from: mailFrom, to: recipients)
        } catch SMTPError.signInRefused {
            await tokens.invalidate()
            try await attempt(message, from: mailFrom, to: recipients)
        }
    }

    private func attempt(_ message: Data, from mailFrom: String, to recipients: [String]) async throws {
        let connection = SMTPConnection(host: host, port: port)
        connection.open()
        defer { connection.close() }
        try expect(220, try await connection.reply())  // the greeting
        try await connection.send("EHLO mailmatej.local")
        let ehlo = try await connection.reply()
        try expect(250, ehlo)
        let token = try await tokens.accessToken()
        let sasl = Data("user=\(email)\u{1}auth=Bearer \(token)\u{1}\u{1}".utf8).base64EncodedString()
        try await connection.send("AUTH XOAUTH2 \(sasl)")
        var auth = try await connection.reply()
        if auth.code == 334 {  // a failed XOAUTH2 explains itself, then wants an empty line
            try await connection.send("")
            auth = try await connection.reply()
        }
        guard auth.code == 235 else { throw SMTPError.signInRefused("\(auth.code) \(auth.text)") }
        // 8-bit headers and bodies pass as they are where the server says it takes them (Gmail does).
        let eightBit = ehlo.lines.contains { $0.uppercased().hasPrefix("8BITMIME") }
        try await connection.send("MAIL FROM:<\(mailFrom)>" + (eightBit ? " BODY=8BITMIME" : ""))
        try expect(250, try await connection.reply())
        for recipient in recipients {
            try await connection.send("RCPT TO:<\(recipient)>")
            let reply = try await connection.reply()
            guard reply.code == 250 || reply.code == 251 else { throw SMTPError.refused(code: reply.code, reply.text) }
        }
        try await connection.send("DATA")
        try expect(354, try await connection.reply())
        try await connection.write(Self.dataLines(message))
        try expect(250, try await connection.reply())
        try? await connection.send("QUIT")
    }

    private func expect(_ code: Int, _ reply: SMTPConnection.Reply) throws {
        guard reply.code == code else { throw SMTPError.refused(code: reply.code, reply.text) }
    }

    /// A message as DATA sends it: lines ending in CRLF (a bare LF made one), a line starting with "."
    /// given another (RFC 5321 §4.5.2), and the closing "." line.
    static func dataLines(_ message: Data) -> Data {
        var out = Data()
        out.reserveCapacity(message.count + message.count / 50 + 5)
        var lineStart = true
        var previous: UInt8 = 0
        for byte in message {
            if lineStart, byte == UInt8(ascii: ".") { out.append(UInt8(ascii: ".")) }
            if byte == 0x0A, previous != 0x0D { out.append(0x0D) }
            out.append(byte)
            lineStart = byte == 0x0A
            previous = byte
        }
        if !lineStart { out.append(contentsOf: [0x0D, 0x0A]) }
        out.append(contentsOf: Array(".\r\n".utf8))
        return out
    }
}

/// A TLS connection to an SMTP server: commands as lines, replies as their code and text lines.
final class SMTPConnection: @unchecked Sendable {
    struct Reply: Sendable {
        var code: Int
        /// Each line's text after the code ("PIPELINING", "8BITMIME", …).
        var lines: [String]
        var text: String { lines.joined(separator: " ") }
    }

    private let task: URLSessionStreamTask
    private var buffer: [UInt8] = []
    private let timeout: Double

    init(host: String, port: Int, timeout: Double = 120) {
        task = URLSession.shared.streamTask(withHostName: host, port: port)
        self.timeout = timeout
    }

    /// Cancelled when dropped: CFNetwork uses a task it is still connecting after it's freed (a crash).
    deinit { task.cancel() }

    func open() {
        task.startSecureConnection()
        task.resume()
    }

    func close() {
        task.closeWrite()
        task.cancel()
    }

    func send(_ line: String) async throws {
        try await write(Data((line + "\r\n").utf8))
    }

    func write(_ data: Data) async throws {
        do {
            try await task.writeOnce(data, timeout: timeout)
        } catch {
            throw GmailSMTP.SMTPError.closed
        }
    }

    /// One reply: "250-…" lines go on, "250 …" ends it.
    func reply() async throws -> Reply {
        var lines: [String] = []
        while true {
            let line = try await readLine()
            guard let parsed = Self.parse(line) else { throw GmailSMTP.SMTPError.closed }
            lines.append(parsed.text)
            if parsed.last { return Reply(code: parsed.code, lines: lines) }
        }
    }

    /// "250-SIZE 35882577" → (250, "SIZE 35882577", false); "250 OK" → (250, "OK", true).
    static func parse(_ line: String) -> (code: Int, text: String, last: Bool)? {
        guard line.count >= 3, let code = Int(line.prefix(3)) else { return nil }
        let rest = line.dropFirst(3)
        return (code, String(rest.dropFirst()), rest.first != "-")
    }

    private func readLine() async throws -> String {
        while true {
            if let end = buffer.firstIndex(of: 0x0A) {
                var line = Array(buffer[..<end])
                if line.last == 0x0D { line.removeLast() }
                buffer.removeFirst(end + 1)
                return String(decoding: line, as: UTF8.self)
            }
            let data: Data?, atEnd: Bool
            do {
                (data, atEnd) = try await task.readOnce(minLength: 1, maxLength: 65536, timeout: timeout)
            } catch {
                throw GmailSMTP.SMTPError.closed
            }
            if let data, !data.isEmpty { buffer.append(contentsOf: data) } else if atEnd { throw GmailSMTP.SMTPError.closed }
        }
    }
}
