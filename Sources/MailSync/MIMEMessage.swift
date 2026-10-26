import Foundation

/// A MIME part of a raw message (RFC 2045/2046), parsed locally: its headers, and either sub-parts
/// (multipart) or content. Part ids number the parts as IMAP does: "1", "1.2", … ("" is the message).
final class MIMEPart {
    let partId: String
    let headers: [(name: String, value: String)]
    let children: [MIMEPart]
    /// The content as stored, still in its transfer encoding (leaves only).
    private let encoded: Data

    init(partId: String, headers: [(name: String, value: String)], children: [MIMEPart], encoded: Data) {
        self.partId = partId
        self.headers = headers
        self.children = children
        self.encoded = encoded
    }

    /// The first header named `name` (case ignored), unfolded.
    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// "text/plain" when the part says nothing (RFC 2045's default).
    var type: String { MailHeaders.value(of: header("Content-Type")).flatMap { $0.contains("/") ? $0 : nil } ?? "text/plain" }

    /// The content with its transfer encoding removed.
    var content: Data {
        switch MailHeaders.value(of: header("Content-Transfer-Encoding")) ?? "" {
        case "base64":
            return Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) ?? Data()
        case "quoted-printable":
            return MailHeaders.quotedPrintable(bytes: [UInt8](encoded))
        default:
            return encoded
        }
    }

    var size: Int { encoded.count }

    /// The part with this id, here or below.
    func find(_ id: String) -> MIMEPart? {
        if partId == id { return self }
        for child in children {
            if let found = child.find(id) { return found }
        }
        return nil
    }

    /// Parses a whole raw message.
    static func parse(_ data: Data) -> MIMEPart { parse(data[...], partId: "") }

    private static let crlfcrlf = Data("\r\n\r\n".utf8), lflf = Data("\n\n".utf8)

    private static func parse(_ data: Data.SubSequence, partId: String) -> MIMEPart {
        // Headers end at the first empty line.
        let headerEnd = data.range(of: crlfcrlf).map { ($0.lowerBound, $0.upperBound) }
            ?? data.range(of: lflf).map { ($0.lowerBound, $0.upperBound) }
        let headerBytes = headerEnd.map { data[data.startIndex..<$0.0] } ?? data
        let body = headerEnd.map { data[$0.1...] } ?? data[data.endIndex...]
        let headers = parseHeaders(headerBytes)
        let contentType = headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
        let type = MailHeaders.value(of: contentType) ?? "text/plain"
        if type.hasPrefix("multipart/"), let boundary = MailHeaders.parameter("boundary", in: contentType), !boundary.isEmpty {
            let pieces = split(body, boundary: boundary)
            let children = pieces.enumerated().map { index, piece in
                parse(piece, partId: partId.isEmpty ? "\(index + 1)" : "\(partId).\(index + 1)")
            }
            return MIMEPart(partId: partId, headers: headers, children: children, encoded: Data())
        }
        return MIMEPart(partId: partId, headers: headers, children: [], encoded: Data(body))
    }

    /// Header lines, unfolded (a line starting with whitespace continues the one before).
    private static func parseHeaders(_ bytes: Data.SubSequence) -> [(name: String, value: String)] {
        // Header bytes are usually ASCII; 8-bit ones are mostly UTF-8, else Latin-1.
        let text = String(data: Data(bytes), encoding: .utf8) ?? String(data: Data(bytes), encoding: .isoLatin1) ?? ""
        var headers: [(name: String, value: String)] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = line.first, first == " " || first == "\t", !headers.isEmpty {
                headers[headers.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                headers.append((String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                                String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
            }
        }
        return headers
    }

    /// A multipart body's parts: what lies between its "--boundary" lines, up to "--boundary--".
    private static func split(_ body: Data.SubSequence, boundary: String) -> [Data.SubSequence] {
        let delimiter = Data(("--" + boundary).utf8)
        var parts: [Data.SubSequence] = []
        var searchFrom = body.startIndex
        var partStart: Data.Index?
        while let found = body.range(of: delimiter, in: searchFrom..<body.endIndex) {
            // A delimiter counts only at the start of a line.
            let atLineStart = found.lowerBound == body.startIndex || body[found.lowerBound - 1] == 0x0A
            guard atLineStart else {
                searchFrom = found.upperBound
                continue
            }
            if let start = partStart {
                // The line break before the delimiter belongs to it, not to the part.
                var end = found.lowerBound
                if end > start, body[end - 1] == 0x0A { end -= 1 }
                if end > start, body[end - 1] == 0x0D { end -= 1 }
                parts.append(body[start..<end])
            }
            var after = found.upperBound
            if after + 1 < body.endIndex, body[after] == 0x2D, body[after + 1] == 0x2D { return parts }  // "--": the end
            // Skip to the next line.
            while after < body.endIndex, body[after] != 0x0A { after += 1 }
            partStart = min(after + 1, body.endIndex)
            searchFrom = partStart!
        }
        if let start = partStart, start < body.endIndex { parts.append(body[start...]) }  // no closing delimiter
        return parts
    }
}
