import Foundation

/// Readable text from HTML, for the search index and previews: style, script, head and title dropped
/// with what's in them, a line break where a line or block ends, other tags dropped, the common
/// entities decoded and whitespace collapsed. `byExpressions` says it in regular expressions; `scanned`
/// does the same in a pass over the bytes for each, about ten times as fast (a newsletter's HTML took
/// half a millisecond the other way), and leaves to the expressions what it can't be sure of (`Unsure`).
enum HTMLText {
    static func plainText(_ html: String) -> String {
        (try? scanned(html)) ?? byExpressions(html)
    }

    static func byExpressions(_ html: String) -> String {
        var s = html.replacingOccurrences(
            of: #"(?is)<(style|script|head|title)\b.*?</\1>"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)<(br|/p|/div|/tr|/li|/h\d)\b[^>]*>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        for (entity, char) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        s = s.replacingOccurrences(of: #"[ \t\r\f]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*\n\s*"#, with: "\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where the expressions' Unicode rules and the bytes might not agree: a tag's name meeting other
    /// than ASCII (ſ is s to them, ﬆ is st, and whether a name ends depends on the letter or mark after
    /// it; \d is any decimal digit), or an entity's (Foundation's search takes the Greek question mark
    /// for a semicolon, and has its own idea of what may follow &#39;).
    struct Unsure: Error {}

    /// `byExpressions`, each expression a pass over the bytes.
    static func scanned(_ html: String) throws -> String {
        var bytes = Array(html.utf8)
        bytes = try droppingBlocks(bytes)
        bytes = try breakingLines(bytes)
        bytes = droppingTags(bytes)
        bytes = try decodingEntities(bytes)
        bytes = collapsingSpaces(bytes)
        bytes = joiningLines(bytes)
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let blockNames = ["style", "script", "head", "title"].map { Array($0.utf8) }
    private static let lineNames = ["br", "/p", "/div", "/tr", "/li"].map { Array($0.utf8) }
    private static let heading = Array("/h".utf8)
    private static let entities: [(name: [UInt8], char: UInt8)] = [
        ("nbsp;", " "), ("lt;", "<"), ("gt;", ">"), ("quot;", "\""), ("#39;", "'"), ("amp;", "&"),
    ].map { (Array($0.0.utf8), $0.1.utf8.first!) }

    private static let less = UInt8(ascii: "<"), greater = UInt8(ascii: ">"), slash = UInt8(ascii: "/")
    private static let ampersand = UInt8(ascii: "&"), space = UInt8(ascii: " "), newline = UInt8(ascii: "\n")

    /// `(?is)<(style|script|head|title)\b.*?</\1>` replaced with a space.
    private static func droppingBlocks(_ a: [UInt8]) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(a.count)
        // Each name's last search for its closing tag, so one never closed isn't looked for to the end
        // again at every later opening.
        var searched: [(from: Int, at: Int?)?] = Array(repeating: nil, count: blockNames.count)
        var i = 0
        scan: while i < a.count {
            if a[i] == less {
                for (n, name) in blockNames.enumerated() {
                    guard try has(name, in: a, at: i + 1) else { continue }
                    let end = i + 1 + name.count
                    guard try endsWord(a, at: end) else { break }
                    let close: Int?
                    if let last = searched[n], last.from <= end, last.at.map({ end <= $0 }) ?? true {
                        close = last.at
                    } else {
                        close = try closing(name, in: a, from: end)
                        searched[n] = (end, close)
                    }
                    guard let close else { break }
                    out.append(space)
                    i = close + name.count + 3  // "</", the name, ">"
                    continue scan
                }
            }
            i = copy(a, from: i, upTo: less, into: &out)
        }
        return out
    }

    /// Where the first `</name>` (in any case) at or after `i` starts.
    private static func closing(_ name: [UInt8], in a: [UInt8], from i: Int) throws -> Int? {
        var j = i
        while j + 1 < a.count {
            if a[j] == less, a[j + 1] == slash, try has(name, in: a, at: j + 2) {
                let end = j + 2 + name.count
                if end < a.count, a[end] == greater { return j }
            }
            j += 1
        }
        return nil
    }

    /// `(?i)<(br|/p|/div|/tr|/li|/h\d)\b[^>]*>` replaced with a line break.
    private static func breakingLines(_ a: [UInt8]) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(a.count)
        var closer = Closer(a)
        var i = 0
        while i < a.count {
            if a[i] == less, let end = try lineName(in: a, at: i + 1), try endsWord(a, at: end), let close = closer.first(from: end) {
                out.append(newline)
                i = close + 1
                continue
            }
            i = copy(a, from: i, upTo: less, into: &out)
        }
        return out
    }

    /// Where the name of a tag that ends a line (see `breakingLines`) at `i` ends, if there's one.
    private static func lineName(in a: [UInt8], at i: Int) throws -> Int? {
        for name in lineNames {
            if try has(name, in: a, at: i) { return i + name.count }
        }
        guard try has(heading, in: a, at: i), i + 2 < a.count else { return nil }
        let digit = a[i + 2]
        guard digit < 0x80 else { throw Unsure() }
        return digit >= UInt8(ascii: "0") && digit <= UInt8(ascii: "9") ? i + 3 : nil
    }

    /// `<[^>]+>` replaced with a space.
    private static func droppingTags(_ a: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(a.count)
        var closer = Closer(a)
        var i = 0
        while i < a.count {
            if a[i] == less, let close = closer.first(from: i + 1), close > i + 1 {
                out.append(space)
                i = close + 1
                continue
            }
            i = copy(a, from: i, upTo: less, into: &out)
        }
        return out
    }

    /// The entities decoded, as Foundation's search for each finds them (they can't overlap, so one
    /// pass does them all): not one followed by a character that extends its semicolon. For &#39; it
    /// skips a different set, all characters that join the one before them: one of those is left to the
    /// expressions.
    private static func decodingEntities(_ a: [UInt8]) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(a.count)
        var i = 0
        scan: while i < a.count {
            if a[i] == ampersand {
                for (name, char) in entities {
                    guard try has(name, in: a, at: i + 1, anyCase: false) else { continue }
                    let end = i + 1 + name.count
                    if end < a.count, a[end] >= 0x80 {
                        let next = scalar(in: a, at: end)
                        if char == UInt8(ascii: "'") {
                            if joins(next) { throw Unsure() }
                        } else if extends(next) {
                            break
                        }
                    }
                    out.append(char)
                    i = end
                    continue scan
                }
            }
            i = copy(a, from: i, upTo: ampersand, into: &out)
        }
        return out
    }

    /// `[ \t\r\f]+` replaced with a space.
    private static func collapsingSpaces(_ a: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(a.count)
        var spaced = false
        for c in a {
            if c == space || c == 0x09 || c == 0x0D || c == 0x0C {
                if !spaced { out.append(space) }
                spaced = true
            } else {
                out.append(c)
                spaced = false
            }
        }
        return out
    }

    /// `\s*\n\s*` replaced with a line break: each run of whitespace with a line break in it.
    private static func joiningLines(_ a: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(a.count)
        var i = 0
        while i < a.count {
            let start = i
            var breaks = false
            while i < a.count, let length = whitespaceLength(a, at: i) {
                breaks = breaks || a[i] == newline
                i += length
            }
            if i == start {
                out.append(a[i])
                i += 1
            } else if breaks {
                out.append(newline)
            } else {
                out.append(contentsOf: a[start..<i])
            }
        }
        return out
    }

    /// Copies the bytes from `i` (where nothing's been found) up to the next `marker`, where the next
    /// thing might be, and returns where that is.
    private static func copy(_ a: [UInt8], from i: Int, upTo marker: UInt8, into out: inout [UInt8]) -> Int {
        let next = a[(i + 1)...].firstIndex(of: marker) ?? a.count
        out.append(contentsOf: a[i..<next])
        return next
    }

    /// Whether `a` has `literal` (lowercase ASCII) at `i`: in any case, or else exactly.
    private static func has(_ literal: [UInt8], in a: [UInt8], at i: Int, anyCase: Bool = true) throws -> Bool {
        for (k, expected) in literal.enumerated() {
            guard i + k < a.count else { return false }
            var c = a[i + k]
            guard c < 0x80 else { throw Unsure() }
            if anyCase, c >= UInt8(ascii: "A"), c <= UInt8(ascii: "Z") { c += 0x20 }
            if c != expected { return false }
        }
        return true
    }

    /// `\b` after a name (which ends in a word character) at `i`: the end, or other than a letter, a
    /// digit or _.
    private static func endsWord(_ a: [UInt8], at i: Int) throws -> Bool {
        guard i < a.count else { return true }
        let c = a[i]
        guard c < 0x80 else { throw Unsure() }
        let isWord = (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) || (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z"))
            || (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")) || c == UInt8(ascii: "_")
        return !isWord
    }

    /// The length of the whitespace character at `i` (Unicode's, as `\s` has it), if it's one.
    private static func whitespaceLength(_ a: [UInt8], at i: Int) -> Int? {
        let c = a[i]
        if c < 0x80 { return (c >= 0x09 && c <= 0x0D) || c == space ? 1 : nil }
        // Beyond ASCII only U+0085, U+00A0, U+1680, U+2000 to U+205F and U+3000 are, which start so.
        guard c == 0xC2 || c == 0xE1 || c == 0xE2 || c == 0xE3, scalar(in: a, at: i).properties.isWhitespace else { return nil }
        return c == 0xC2 ? 2 : 3
    }

    /// Whether Foundation's search takes a character as part of the one before it: a combining mark, a
    /// zero-width non-joiner, an emoji's skin tone (but none of Apple's private ones). Checked for every
    /// character: a search for "&lt;" followed by each fails just for these.
    private static func extends(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        return (properties.isGraphemeExtend || properties.isEmojiModifier) && properties.generalCategory != .privateUse
    }

    /// Whether a character makes one with the character before it.
    private static func joins(_ scalar: Unicode.Scalar) -> Bool {
        var pair = "x"
        pair.unicodeScalars.append(scalar)
        return pair.count == 1
    }

    /// The character starting at `i`.
    private static func scalar(in a: [UInt8], at i: Int) -> Unicode.Scalar {
        var bytes = a[i...].makeIterator()
        var decoder = UTF8()
        if case .scalarValue(let scalar) = decoder.decode(&bytes) { return scalar }
        return "\u{FFFD}"
    }

    /// Finds the first `>` at or after a place, keeping what it found last: the places asked about go
    /// forward, so the bytes are mostly looked at once.
    private struct Closer {
        let bytes: [UInt8]
        private var from = Int.max
        private var found: Int?

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func first(from i: Int) -> Int? {
            if i >= from, found.map({ i <= $0 }) ?? true { return found }
            from = i
            found = bytes[i...].firstIndex(of: UInt8(ascii: ">"))
            return found
        }
    }
}
