import Foundation

/// Reading message headers as written (RFC 5322), for accounts whose server hands them over unparsed
/// (Gmail): encoded words, address lists, Message-ID lists and dates.
enum MailHeaders {
    // MARK: Encoded words (RFC 2047)

    /// Decodes `=?charset?B|Q?text?=` words; whitespace between two encoded words goes, as the RFC says.
    static func decodeWords(_ text: String) -> String {
        guard text.contains("=?") else { return text }
        let pattern = #"=\?([^?\s]+)\?([BbQq])\?([^?\s]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        var previousWasWord = false
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let between = ns.substring(with: NSRange(location: last, length: match.range.location - last))
            if !(previousWasWord && between.allSatisfy(\.isWhitespace)) { out += between }
            let charset = ns.substring(with: match.range(at: 1))
            let encoding = ns.substring(with: match.range(at: 2)).uppercased()
            let payload = ns.substring(with: match.range(at: 3))
            let bytes: Data?
            if encoding == "B" {
                bytes = Data(base64Encoded: payload.padding(toLength: (payload.count + 3) / 4 * 4, withPad: "=", startingAt: 0))
            } else {
                bytes = quotedPrintable(payload.replacingOccurrences(of: "_", with: " "), header: true)
            }
            if let bytes, let decoded = string(bytes, charset: charset) {
                out += decoded
            } else {
                out += ns.substring(with: match.range)
            }
            last = match.range.location + match.range.length
            previousWasWord = true
        }
        out += ns.substring(from: last)
        return out
    }

    /// Quoted-printable text as bytes (`header`: as in encoded words, no soft line breaks).
    static func quotedPrintable(_ text: String, header: Bool = false) -> Data? {
        quotedPrintable(bytes: Array(text.utf8), header: header)
    }

    /// Decodes quoted-printable: "=XX" is a byte, "=" at a line's end joins it to the next line.
    static func quotedPrintable(bytes chars: [UInt8], header: Bool = false) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chars.count)
        func hex(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: c - 0x30
            case 0x41...0x46: c - 0x41 + 10
            case 0x61...0x66: c - 0x61 + 10
            default: nil
            }
        }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == UInt8(ascii: "=") {
                if !header {  // soft line break: "=" then optional spaces, then the line end
                    var j = i + 1
                    while j < chars.count, chars[j] == 0x20 || chars[j] == 0x09 { j += 1 }
                    if j < chars.count, chars[j] == 0x0D || chars[j] == 0x0A {
                        i = j + (chars[j] == 0x0D && j + 1 < chars.count && chars[j + 1] == 0x0A ? 2 : 1)
                        continue
                    }
                    if j == chars.count {
                        i = j
                        continue
                    }
                }
                if i + 2 < chars.count, let high = hex(chars[i + 1]), let low = hex(chars[i + 2]) {
                    bytes.append(high << 4 | low)
                    i += 3
                    continue
                }
            }
            bytes.append(c)
            i += 1
        }
        return Data(bytes)
    }

    /// Text in a charset by its MIME name; nil when the name is unknown or the bytes don't fit it.
    static func string(_ data: Data, charset: String?) -> String? {
        let name = (charset ?? "utf-8").trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased()
        if name == "utf-8" || name == "utf8" || name == "us-ascii" || name == "ascii" {
            return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        }
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf)))
    }

    /// Text in a part's charset, falling back to UTF-8 (lossy) and then Latin-1 so something shows.
    static func text(_ data: Data, charset: String?) -> String {
        string(data, charset: charset) ?? String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
    }

    // MARK: Addresses

    struct Address: Equatable {
        var name: String?
        var email: String
    }

    /// The addresses of an address header ("Ann <a@x>, "Doe, J" <j@x>, b@y, Team: c@z;"), and the
    /// names of groups with no addresses ("undisclosed-recipients:;"), which MailMate shows.
    static func addresses(_ header: String) -> (addresses: [Address], emptyGroups: [String]) {
        var addresses: [Address] = []
        var emptyGroups: [String] = []
        var tokens = tokenize(header)
        // Groups: "name: members;" — members are listed as addresses; an empty one is kept by name.
        var groupName: String?
        var groupCount = 0
        var current: [Token] = []
        func flush() {
            if let address = address(from: current) {
                addresses.append(address)
                groupCount += 1
            }
            current = []
        }
        while !tokens.isEmpty {
            let token = tokens.removeFirst()
            switch token {
            case .special(":") where groupName == nil && !current.contains(where: { if case .angle = $0 { true } else { false } }):
                groupName = current.map(\.text).joined(separator: " ")
                groupCount = 0
                current = []
            case .special(";"):
                flush()
                if let name = groupName, groupCount == 0, !name.isEmpty { emptyGroups.append(decodeWords(name)) }
                groupName = nil
            case .special(","):
                flush()
            default:
                current.append(token)
            }
        }
        flush()
        if let name = groupName, groupCount == 0, !name.isEmpty { emptyGroups.append(decodeWords(name)) }
        return (addresses, emptyGroups)
    }

    private enum Token {
        case word(String)
        case quoted(String)
        case angle(String)
        case special(Character)

        var text: String {
            switch self {
            case .word(let s), .quoted(let s), .angle(let s): s
            case .special(let c): String(c)
            }
        }
    }

    /// Words, quoted strings, <addr-specs> and the separators , : ; (comments dropped).
    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var word = ""
        var chars = Array(text)[...]
        func endWord() {
            if !word.isEmpty { tokens.append(.word(word)) }
            word = ""
        }
        while let c = chars.popFirst() {
            switch c {
            case "\"":
                endWord()
                var quoted = ""
                while let q = chars.popFirst(), q != "\"" {
                    if q == "\\", let escaped = chars.popFirst() { quoted.append(escaped) } else { quoted.append(q) }
                }
                tokens.append(.quoted(quoted))
            case "<":
                endWord()
                var inner = ""
                while let q = chars.popFirst(), q != ">" { inner.append(q) }
                tokens.append(.angle(inner.trimmingCharacters(in: .whitespaces)))
            case "(":
                endWord()
                var depth = 1
                while depth > 0, let q = chars.popFirst() {
                    if q == "\\" { _ = chars.popFirst() } else if q == "(" { depth += 1 } else if q == ")" { depth -= 1 }
                }
            case ",", ";", ":":
                endWord()
                tokens.append(.special(c))
            case _ where c.isWhitespace:
                endWord()
            default:
                word.append(c)
            }
        }
        endWord()
        return tokens
    }

    /// One mailbox from its tokens: "<addr>" with the words before it as the name, or a bare address.
    private static func address(from tokens: [Token]) -> Address? {
        guard !tokens.isEmpty else { return nil }
        if let index = tokens.lastIndex(where: { if case .angle = $0 { true } else { false } }) {
            let email = tokens[index].text
            guard email.contains("@") else { return nil }
            let name = decodeWords(tokens[..<index].map(\.text).joined(separator: " ")).trimmingCharacters(in: .whitespaces)
            return Address(name: name.isEmpty ? nil : name, email: email)
        }
        let joined = tokens.map(\.text).joined()
        guard joined.contains("@") else { return nil }
        return Address(name: nil, email: joined)
    }

    // MARK: Message-IDs

    /// The Message-IDs in a header ("<a@x> <b@y>"), without angle brackets, in order.
    static func messageIds(_ header: String?) -> [String] {
        guard let header else { return [] }
        var ids: [String] = []
        var rest = header[...]
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            let id = rest[rest.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            if !id.isEmpty { ids.append(id) }
            rest = rest[rest.index(after: close)...]
        }
        if ids.isEmpty {  // Some senders leave out the brackets.
            ids = header.split(whereSeparator: \.isWhitespace).map(String.init).filter { $0.contains("@") }
        }
        return ids
    }

    // MARK: Dates

    /// A Date header (RFC 5322, with the usual deviations: no weekday, no seconds, a zone name).
    static func date(_ header: String?) -> Date? {
        guard var text = header?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)  // "(UTC)"
        if let comma = text.firstIndex(of: ","), text.distance(from: text.startIndex, to: comma) <= 4 {
            text = String(text[text.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
        }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        for format in ["d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm zzz",
                       "d MMM yy HH:mm:ss Z", "d MMM yyyy HH:mm:ss"] {
            if let date = dateFormatter(format).date(from: text) { return date }
        }
        return nil
    }

    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]
    private static let formattersLock = NSLock()

    private static func dateFormatter(_ format: String) -> DateFormatter {
        formattersLock.lock()
        defer { formattersLock.unlock() }
        if let formatter = formatters[format] { return formatter }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        formatters[format] = formatter
        return formatter
    }

    // MARK: Parameters

    /// A header parameter's value ("charset" of "text/plain; charset=utf-8"), quotes removed; RFC 2231
    /// continued and encoded values ("name*0*=utf-8''…") joined and decoded.
    static func parameter(_ name: String, in header: String?) -> String? {
        guard let header else { return nil }
        var plain: String?
        var pieces: [(Int, String, Bool)] = []
        for raw in splitParameters(header).dropFirst() {
            guard let eq = raw.firstIndex(of: "=") else { continue }
            let key = raw[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = raw[raw.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            let target = name.lowercased()
            if key == target {
                plain = value
            } else if key == target + "*" {
                pieces.append((0, value, true))
            } else if key.hasPrefix(target + "*"), let index = Int(key.dropFirst(target.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: "*"))) {
                pieces.append((index, value, key.hasSuffix("*")))
            }
        }
        guard !pieces.isEmpty else { return plain.map(decodeWords) }
        pieces.sort { $0.0 < $1.0 }
        var charset: String?
        var bytes = Data()
        for (index, value, encoded) in pieces {
            var value = value
            if encoded, index == 0, let first = value.firstIndex(of: "'"), let second = value[value.index(after: first)...].firstIndex(of: "'") {
                charset = String(value[..<first])
                value = String(value[value.index(after: second)...])
            }
            if encoded {
                bytes += Data(percentDecoded(value))
            } else {
                bytes += Data(value.utf8)
            }
        }
        return text(bytes, charset: charset)
    }

    private static func percentDecoded(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        let chars = Array(text.utf8)
        var i = 0
        while i < chars.count {
            if chars[i] == UInt8(ascii: "%"), i + 2 < chars.count,
                let value = UInt8(String(bytes: chars[(i + 1)...(i + 2)], encoding: .ascii) ?? "", radix: 16)
            {
                out.append(value)
                i += 3
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }

    /// A header split at semicolons outside quotes: the value, then each parameter.
    private static func splitParameters(_ header: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quoted = false
        for c in header {
            if c == "\"" { quoted.toggle() }
            if c == ";", !quoted {
                parts.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The value before any parameters, lowercased ("text/plain" of "Text/Plain; charset=…").
    static func value(of header: String?) -> String? {
        header.map { (splitParameters($0).first ?? "").lowercased() }
    }

    // MARK: HTML entities

    /// The few entities Gmail's snippets use (&#39; &quot; &amp; &lt; &gt; and numeric ones).
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var rest = text[...]
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            if let semi = rest[amp...].firstIndex(of: ";"), rest.distance(from: amp, to: semi) <= 10 {
                let entity = String(rest[amp...semi])
                if let scalar = numericEntity(entity) {
                    out.append(Character(scalar))
                } else {
                    out += [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "),
                            ("&amp;", "&")].first { $0.0 == entity }?.1 ?? entity
                }
                rest = rest[rest.index(after: semi)...]
            } else {
                out += "&"
                rest = rest[rest.index(after: amp)...]
            }
        }
        return out + rest
    }

    private static func numericEntity(_ entity: String) -> Unicode.Scalar? {
        guard entity.hasPrefix("&#"), entity.hasSuffix(";") else { return nil }
        let body = entity.dropFirst(2).dropLast()
        let value = body.hasPrefix("x") || body.hasPrefix("X") ? UInt32(body.dropFirst(), radix: 16) : UInt32(body)
        return value.flatMap(Unicode.Scalar.init)
    }
}
