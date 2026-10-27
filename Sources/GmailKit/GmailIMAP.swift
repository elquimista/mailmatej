import Foundation

/// Gmail over IMAP (imap.gmail.com), signed in with the same Google token as the API (XOAUTH2), for
/// downloading whole messages fast: IMAP isn't metered per message as the Gmail API is (60 quota units
/// a message against 6,000 a minute), only by volume (about 2.5 GB a day). Read-only (mailboxes are
/// EXAMINEd, bodies fetched with BODY.PEEK). Gmail's extensions give what the API would: each message's
/// Gmail id (X-GM-MSGID, the API's id in decimal), thread (X-GM-THRID) and labels (X-GM-LABELS).
public actor GmailIMAP {
    public struct Message: Sendable {
        public var uid: UInt32
        /// The API's message id (hex).
        public var gmailId: String
        /// The API's thread id (hex).
        public var threadId: String?
        /// Labels as IMAP names them: "\\Inbox", "\\Sent", "\\Important", "Work/Clients".
        public var labels: [String]
        public var flags: Set<String>
        public var internalDate: Date?
        public var size: Int?
        public var raw: Data?
    }

    /// The special mailboxes: everything outside Spam and Trash, Spam, Trash.
    public struct Folders: Sendable {
        public var all: String?
        public var spam: String?
        public var trash: String?
    }

    public enum IMAPError: LocalizedError, Sendable {
        case signInRefused(String)
        case refused(String)
        case closed
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .signInRefused(let why): "Gmail’s IMAP refused the sign-in (\(why))."
            case .refused(let why): "Gmail’s IMAP refused a command (\(why))."
            case .closed: "Gmail’s IMAP connection closed."
            case .malformed(let what): "Gmail’s IMAP answer couldn’t be read (\(what))."
            }
        }
    }

    private let email: String
    private let tokens: GoogleTokenSource
    private let host: String
    private var connection: IMAPConnection?
    private var tag = 0

    public init(email: String, tokens: GoogleTokenSource, host: String = "imap.gmail.com") {
        self.email = email
        self.tokens = tokens
        self.host = host
    }

    // MARK: Session

    /// Connects and signs in (once; later calls reuse the connection).
    public func connect() async throws {
        guard connection == nil else { return }
        let connection = IMAPConnection(host: host, port: 993)
        try await connection.open()
        _ = try await connection.readResponse()  // the greeting
        self.connection = connection
        do {
            let token = try await tokens.accessToken()
            let sasl = Data("user=\(email)\u{1}auth=Bearer \(token)\u{1}\u{1}".utf8).base64EncodedString()
            _ = try await command("AUTHENTICATE XOAUTH2 \(sasl)", onContinuation: Data("\r\n".utf8))
        } catch IMAPError.refused(let why) {
            await close()
            throw IMAPError.signInRefused(why)
        } catch {
            await close()
            throw error
        }
    }

    public func close() async {
        if let connection {
            _ = try? await connection.send(Data("\(nextTag()) LOGOUT\r\n".utf8))
            await connection.close()
        }
        connection = nil
    }

    /// The special mailboxes, by their special-use attributes (names differ by language).
    public func folders() async throws -> Folders {
        var folders = Folders()
        for response in try await command(#"LIST "" "*""#) {
            guard response.count >= 4, response[0].atom == "LIST", case .list(let attributes) = response[1],
                let name = response[3].text
            else { continue }
            let flags = Set(attributes.compactMap(\.atom).map { $0.lowercased() })
            if flags.contains("\\all") { folders.all = name }
            if flags.contains("\\junk") { folders.spam = name }
            if flags.contains("\\trash") { folders.trash = name }
        }
        return folders
    }

    /// Opens a mailbox read-only.
    public func examine(_ mailbox: String) async throws {
        _ = try await command("EXAMINE \(Self.quoted(mailbox))")
    }

    /// Every message in the open mailbox: its UID, Gmail id and size.
    public func index() async throws -> [(uid: UInt32, gmailId: String, size: Int)] {
        try await command("UID FETCH 1:* (UID X-GM-MSGID RFC822.SIZE)").compactMap { response in
            guard let fields = Self.fetchFields(response), let uid = fields["UID"]?.atom.flatMap({ UInt32($0) }),
                let id = fields["X-GM-MSGID"]?.atom.flatMap({ UInt64($0) })
            else { return nil }
            return (uid, String(id, radix: 16), fields["RFC822.SIZE"]?.atom.flatMap { Int($0) } ?? 0)
        }
    }

    /// Messages of the open mailbox: labels, flags, dates and sizes, and with `bodies` the whole message.
    public func fetch(_ uids: [UInt32], bodies: Bool) async throws -> [Message] {
        guard !uids.isEmpty else { return [] }
        let items = "UID X-GM-MSGID X-GM-THRID X-GM-LABELS FLAGS INTERNALDATE RFC822.SIZE" + (bodies ? " BODY.PEEK[]" : "")
        return try await command("UID FETCH \(Self.uidSet(uids)) (\(items))").compactMap { response in
            guard let fields = Self.fetchFields(response), let uid = fields["UID"]?.atom.flatMap({ UInt32($0) }),
                let id = fields["X-GM-MSGID"]?.atom.flatMap({ UInt64($0) })
            else { return nil }
            let labels: [String] = {
                guard case .list(let values)? = fields["X-GM-LABELS"] else { return [] }
                return values.compactMap(\.text).map(Self.decodeModifiedUTF7)
            }()
            let flags: Set<String> = {
                guard case .list(let values)? = fields["FLAGS"] else { return [] }
                return Set(values.compactMap(\.atom))
            }()
            return Message(
                uid: uid, gmailId: String(id, radix: 16),
                threadId: fields["X-GM-THRID"]?.atom.flatMap { UInt64($0) }.map { String($0, radix: 16) },
                labels: labels, flags: flags, internalDate: fields["INTERNALDATE"]?.text.flatMap(Self.internalDate),
                size: fields["RFC822.SIZE"]?.atom.flatMap { Int($0) }, raw: fields["BODY[]"]?.data)
        }
    }

    // MARK: IDLE

    /// Waits for changes in the open mailbox (IMAP IDLE, RFC 2177) and calls `onChange` for each the
    /// server announces (new mail, a message gone, flags changed), for `duration` (IDLE is renewed well
    /// within the 29 minutes servers allow), then ends the IDLE. Reading just waits for the server; a
    /// timer ends the IDLE when its time is up, and if the server doesn't answer that within `timeout`
    /// the connection is taken for dead: closed, and this throws.
    public func idle(for duration: Duration, timeout: Double = 20, onChange: @Sendable () -> Void) async throws {
        guard let connection else { throw IMAPError.closed }
        let tag = nextTag()
        try await connection.send(Data("\(tag) IDLE\r\n".utf8))
        while true {  // "+ idling"
            let response = try await connection.readResponse(timeout: timeout)
            if response.first?.atom == "+" { break }
            if response.first?.atom == tag { throw IMAPError.refused("IDLE") }
        }
        let finished = Finished()
        let renewal = Task {
            try? await Task.sleep(for: duration)
            guard !finished.isSet else { return }
            try? await connection.send(Data("DONE\r\n".utf8))
            try? await Task.sleep(for: .seconds(timeout))
            if !finished.isSet { await connection.close() }  // no answer: the connection is gone
        }
        defer {
            finished.set()
            renewal.cancel()
        }
        let wait = Double(duration.components.seconds) + timeout + 60
        while true {
            let response = try await connection.readResponse(timeout: wait)
            if response.first?.atom == tag { return }  // the IDLE ended (by the timer, or the server)
            if response.first?.atom == "*", response.count >= 3,
                let kind = response[2].atom?.uppercased(), ["EXISTS", "EXPUNGE", "FETCH"].contains(kind)
            {
                onChange()
            }
        }
    }

    /// Set once, from any thread.
    private final class Finished: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    // MARK: Commands

    private func nextTag() -> String {
        tag += 1
        return "m\(tag)"
    }

    /// Sends a command and collects its untagged responses until it completes; NO or BAD throw. A
    /// continuation request ("+ …", a failed XOAUTH2 explaining itself) is answered with `onContinuation`.
    private func command(_ text: String, onContinuation: Data? = nil) async throws -> [[IMAPValue]] {
        guard let connection else { throw IMAPError.closed }
        let tag = nextTag()
        try await connection.send(Data("\(tag) \(text)\r\n".utf8))
        var untagged: [[IMAPValue]] = []
        while true {
            let response = try await connection.readResponse()
            guard let first = response.first?.atom else { continue }
            if first == "*" {
                untagged.append(Array(response.dropFirst()))
            } else if first == "+" {
                try await connection.send(onContinuation ?? Data("\r\n".utf8))
            } else if first == tag {
                let status = response.count > 1 ? response[1].atom?.uppercased() : nil
                guard status == "OK" else {
                    throw IMAPError.refused(response.dropFirst(2).compactMap(\.text).joined(separator: " "))
                }
                return untagged
            }
        }
    }

    // MARK: Values

    /// A FETCH response's items by name ("UID" → 42, "BODY[]" → the message).
    static func fetchFields(_ response: [IMAPValue]) -> [String: IMAPValue]? {
        guard response.count >= 3, response[1].atom?.uppercased() == "FETCH", case .list(let items) = response[2] else { return nil }
        var fields: [String: IMAPValue] = [:]
        var index = 0
        while index + 1 < items.count {
            if let key = items[index].atom?.uppercased() { fields[key] = items[index + 1] }
            index += 2
        }
        return fields
    }

    /// "1:5,9,12:20" for UIDs (sorted, runs as ranges).
    static func uidSet(_ uids: [UInt32]) -> String {
        let sorted = Array(Set(uids)).sorted()
        var parts: [String] = []
        var start = sorted[0], end = sorted[0]
        for uid in sorted.dropFirst() {
            if uid == end + 1 {
                end = uid
            } else {
                parts.append(start == end ? "\(start)" : "\(start):\(end)")
                start = uid
                end = uid
            }
        }
        parts.append(start == end ? "\(start)" : "\(start):\(end)")
        return parts.joined(separator: ",")
    }

    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// "17-Jul-1996 02:44:25 -0700".
    static func internalDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return formatter.date(from: text.trimmingCharacters(in: .whitespaces))
    }

    /// IMAP's modified UTF-7 (RFC 3501 §5.1.3), as Gmail writes non-ASCII label names: "&AOk-" is "é".
    static func decodeModifiedUTF7(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var rest = text[...]
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            guard let dash = rest[amp...].firstIndex(of: "-") else { out += rest[amp...]; return out }
            let encoded = rest[rest.index(after: amp)..<dash]
            if encoded.isEmpty {
                out += "&"
            } else {
                var base64 = encoded.replacingOccurrences(of: ",", with: "/")
                while base64.count % 4 != 0 { base64 += "=" }
                if let data = Data(base64Encoded: base64), let decoded = String(data: data, encoding: .utf16BigEndian) {
                    out += decoded
                } else {
                    out += rest[amp...dash]
                }
            }
            rest = rest[rest.index(after: dash)...]
        }
        return out + rest
    }
}

// MARK: - Responses

/// One value of an IMAP response: an atom (NIL included), a string (quoted or literal), or a list.
indirect enum IMAPValue: Sendable {
    case atom(String)
    case string(Data)
    case list([IMAPValue])

    var atom: String? {
        if case .atom(let text) = self { return text }
        return nil
    }

    /// An atom or string as text (NIL is nil).
    var text: String? {
        switch self {
        case .atom(let text): text.uppercased() == "NIL" ? nil : text
        case .string(let data): String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        case .list: nil
        }
    }

    var data: Data? {
        switch self {
        case .string(let data): data
        case .atom(let text): text.uppercased() == "NIL" ? nil : Data(text.utf8)
        case .list: nil
        }
    }
}

/// Reads IMAP responses: a response is a line, continued after each literal ({n} then n bytes).
struct IMAPResponseParser {
    enum Segment {
        case text([UInt8])
        case literal(Data)
    }

    /// Parses one whole response into its values.
    static func parse(_ segments: [Segment]) -> [IMAPValue] {
        var parser = Cursor(segments: segments)
        var values: [IMAPValue] = []
        while let value = parser.next() { values.append(value) }
        return values
    }

    private struct Cursor {
        let segments: [Segment]
        var segment = 0
        var offset = 0

        init(segments: [Segment]) { self.segments = segments }

        private var current: [UInt8]? {
            guard segment < segments.count, case .text(let bytes) = segments[segment] else { return nil }
            return bytes
        }

        private mutating func skipSpaces() {
            while let bytes = current, offset < bytes.count, bytes[offset] == 0x20 { offset += 1 }
        }

        /// The next value, or nil at a list's end (or the response's).
        mutating func next(inList: Bool = false) -> IMAPValue? {
            skipSpaces()
            guard let bytes = current else { return nil }
            guard offset < bytes.count else { return nil }
            let byte = bytes[offset]
            switch byte {
            case UInt8(ascii: "("):
                offset += 1
                var items: [IMAPValue] = []
                while true {
                    skipSpaces()
                    guard let now = current, offset < now.count else { break }
                    if now[offset] == UInt8(ascii: ")") {
                        offset += 1
                        break
                    }
                    guard let item = next(inList: true) else { break }
                    items.append(item)
                }
                return .list(items)
            case UInt8(ascii: ")") where inList:
                return nil
            case UInt8(ascii: "\""):
                offset += 1
                var text: [UInt8] = []
                while offset < bytes.count, bytes[offset] != UInt8(ascii: "\"") {
                    if bytes[offset] == UInt8(ascii: "\\"), offset + 1 < bytes.count { offset += 1 }
                    text.append(bytes[offset])
                    offset += 1
                }
                offset += 1
                return .string(Data(text))
            case UInt8(ascii: "{"):
                // A literal: "{n}" ends this text; the data is the next segment.
                segment += 1
                offset = 0
                guard segment < segments.count, case .literal(let data) = segments[segment] else { return .string(Data()) }
                segment += 1
                return .string(data)
            default:
                // An atom, brackets and all ("BODY[]", "[ALERT]"), up to a space or parenthesis outside them.
                var text: [UInt8] = []
                var depth = 0
                while offset < bytes.count {
                    let c = bytes[offset]
                    if c == UInt8(ascii: "[") { depth += 1 }
                    if c == UInt8(ascii: "]") { depth -= 1 }
                    if depth <= 0, c == 0x20 || c == UInt8(ascii: "(") || c == UInt8(ascii: ")") { break }
                    text.append(c)
                    offset += 1
                }
                return .atom(String(decoding: text, as: UTF8.self))
            }
        }
    }
}

/// A TLS connection reading whole IMAP responses (literals included).
actor IMAPConnection {
    private let task: URLSessionStreamTask
    private var buffer: [UInt8] = []
    private var bufferStart = 0

    init(host: String, port: Int) {
        task = URLSession.shared.streamTask(withHostName: host, port: port)
    }

    func open() async throws {
        task.startSecureConnection()
        task.resume()
    }

    func close() {
        task.closeWrite()
        task.cancel()
    }

    func send(_ data: Data) async throws {
        try await task.write(data, timeout: 60)
    }

    /// One response, parsed.
    func readResponse() async throws -> [IMAPValue] {
        try await readResponse(timeout: 120)
    }

    /// One response, parsed; it must start within `timeout` seconds (else the connection counts as gone).
    func readResponse(timeout: Double) async throws -> [IMAPValue] {
        do {
            return try await readWholeResponse(firstLineTimeout: timeout)
        } catch let error as GmailIMAP.IMAPError {
            throw error
        } catch {
            throw GmailIMAP.IMAPError.closed  // timed out (URL or POSIX error), or closed under it
        }
    }

    private func readWholeResponse(firstLineTimeout: Double) async throws -> [IMAPValue] {
        var segments: [IMAPResponseParser.Segment] = []
        var first = true
        while true {
            let line = try await readLine(timeout: first ? firstLineTimeout : 120)
            first = false
            segments.append(.text(line))
            // A line ending in "{n}" (or "{n+}") is followed by n bytes, then the response goes on.
            guard line.last == UInt8(ascii: "}"), let open = line.lastIndex(of: UInt8(ascii: "{")),
                let count = Int(String(decoding: line[(open + 1)..<(line.count - 1)].filter { $0 != UInt8(ascii: "+") }, as: UTF8.self))
            else { break }
            segments.append(.literal(try await readBytes(count)))
        }
        return IMAPResponseParser.parse(segments)
    }

    private func fill(timeout: Double = 120) async throws {
        let (data, atEnd) = try await task.readData(ofMinLength: 1, maxLength: 1 << 20, timeout: timeout)
        if let data, !data.isEmpty {
            if bufferStart > 0, bufferStart > buffer.count / 2 {
                buffer.removeFirst(bufferStart)
                bufferStart = 0
            }
            buffer.append(contentsOf: data)
        } else if atEnd {
            throw GmailIMAP.IMAPError.closed
        }
    }

    private func readLine(timeout: Double = 120) async throws -> [UInt8] {
        while true {
            if let end = buffer[bufferStart...].firstIndex(of: 0x0A) {
                var line = Array(buffer[bufferStart..<end])
                if line.last == 0x0D { line.removeLast() }
                bufferStart = end + 1
                return line
            }
            try await fill(timeout: timeout)
        }
    }

    private func readBytes(_ count: Int) async throws -> Data {
        while buffer.count - bufferStart < count { try await fill() }
        let data = Data(buffer[bufferStart..<(bufferStart + count)])
        bufferStart += count
        return data
    }
}
