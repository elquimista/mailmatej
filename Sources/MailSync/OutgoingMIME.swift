import Foundation
import JMAPKit

/// An outgoing message written out whole (RFC 5322 with MIME, RFC 2045–2049), for servers that take
/// mail that way (Gmail). Laid out as `JMAPAccountSync.emailObject` lays out the JMAP Email:
/// mixed [ related [ alternative [text, html], inline pictures ], attachments ]. Headers that aren't
/// ASCII are encoded words (RFC 2047), file names RFC 2231 parameters; bodies are quoted-printable
/// (7bit when they can be), attachments base64; lines end in CRLF and stay within 78 characters where
/// they can.
public enum OutgoingMIME {
    /// A part to attach, with its bytes: a file, or a part of another message fetched for it.
    public struct Attachment: Sendable {
        public var name: String?
        public var type: String
        public var data: Data
        /// Shown in the HTML (`cid:` in it): sent inline, inside multipart/related.
        public var cid: String?

        public init(name: String?, type: String, data: Data, cid: String? = nil) {
            self.name = name
            self.type = type
            self.data = data
            self.cid = cid
        }
    }

    /// The whole message. `bcc`: whether Bcc is written (Gmail takes the recipients from the headers and
    /// leaves Bcc out of what it delivers; a draft keeps it). `asDraft`: also the format the text is
    /// written in, so the draft reopens as written (see `JMAPAccountSync.draftFormatHeader`).
    public static func message(
        _ message: OutgoingMessage, attachments: [Attachment], bcc: Bool, asDraft: Bool = false,
        date: Date = Date(), messageId: String? = nil
    ) -> Data {
        var head: [String] = []
        head.append(header("Date", dateText(date)))
        head.append(addressHeader("From", [message.from]))
        if !message.to.isEmpty { head.append(addressHeader("To", message.to)) }
        if !message.cc.isEmpty { head.append(addressHeader("Cc", message.cc)) }
        if bcc, !message.bcc.isEmpty { head.append(addressHeader("Bcc", message.bcc)) }
        if !message.replyTo.isEmpty { head.append(addressHeader("Reply-To", message.replyTo)) }
        head.append(header("Subject", message.subject, encode: true))
        let domain = message.from.email?.split(separator: "@").last.map(String.init) ?? "mailmatej.local"
        head.append(header("Message-ID", "<" + (messageId ?? "\(UUID().uuidString)@\(domain)") + ">"))
        if !message.inReplyTo.isEmpty { head.append(idsHeader("In-Reply-To", message.inReplyTo)) }
        if !message.references.isEmpty { head.append(idsHeader("References", message.references)) }
        head.append("MIME-Version: 1.0")
        // As MailMate does: Outlook users can't send reactions, which arrive as stray emails elsewhere.
        head.append("X-MS-Reactions: disallow")
        if asDraft, let format = message.draftFormat { head.append(header(JMAPAccountSync.draftFormatHeader, format)) }

        let text = textPart(message.text, subtype: "plain")
        var body: Part
        if let html = message.html {
            body = .multipart("alternative", [text, textPart(html, subtype: "html")])
            let shown = attachments.filter { part in part.cid.map { html.contains("cid:" + $0) } ?? false }
            let attached = attachments.filter { part in !shown.contains { $0.cid == part.cid && $0.data == part.data } }
            if !shown.isEmpty { body = .multipart("related", [body] + shown.map { filePart($0, inline: true) }) }
            if !attached.isEmpty { body = .multipart("mixed", [body] + attached.map { filePart($0, inline: false) }) }
        } else if !attachments.isEmpty {
            body = .multipart("mixed", [text] + attachments.map { filePart($0, inline: false) })
        } else {
            body = text
        }
        return Data((head.joined(separator: "\r\n") + "\r\n").utf8) + body.data
    }

    // MARK: Parts

    /// A body part: its own headers and content, or parts inside a multipart.
    indirect enum Part {
        case leaf(headers: [String], content: String)
        case multipart(String, [Part])

        /// As written inside its parent (or as the message body after the message's own headers).
        var data: Data {
            switch self {
            case .leaf(let headers, let content):
                return Data((headers.joined(separator: "\r\n") + "\r\n\r\n" + content).utf8)
            case .multipart(let subtype, let parts):
                let boundary = "=_mmj_" + UUID().uuidString
                var data = Data("Content-Type: multipart/\(subtype);\r\n boundary=\"\(boundary)\"\r\n\r\n".utf8)
                for part in parts {
                    data += Data("--\(boundary)\r\n".utf8)
                    data += part.data
                    data += Data("\r\n".utf8)
                }
                data += Data("--\(boundary)--\r\n".utf8)
                return data
            }
        }
    }

    /// Text in UTF-8: as it is when it's ASCII in short lines, else quoted-printable.
    static func textPart(_ text: String, subtype: String) -> Part {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        let plain = text.allSatisfy { $0.isASCII } && lines.allSatisfy { $0.utf8.count <= 76 && !$0.hasSuffix(" ") }
        return .leaf(
            headers: ["Content-Type: text/\(subtype); charset=utf-8",
                      "Content-Transfer-Encoding: " + (plain ? "7bit" : "quoted-printable")],
            content: plain ? lines.joined(separator: "\r\n") : quotedPrintable(lines))
    }

    static func filePart(_ file: Attachment, inline: Bool) -> Part {
        var headers = ["Content-Type: " + file.type + (file.name.map { ";\r\n " + parameter("name", $0) } ?? "")]
        headers.append("Content-Disposition: " + (inline ? "inline" : "attachment")
            + (file.name.map { ";\r\n " + parameter("filename", $0) } ?? ""))
        if let cid = file.cid { headers.append("Content-ID: <\(cid)>") }
        headers.append("Content-Transfer-Encoding: base64")
        return .leaf(headers: headers, content: file.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]))
    }

    /// `name="value"`, or RFC 2231's `name*=utf-8''value` for a value that isn't plain ASCII.
    static func parameter(_ name: String, _ value: String) -> String {
        if value.allSatisfy({ $0.isASCII && !$0.isNewline }) {
            return name + "=\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var allowed = CharacterSet.alphanumerics.intersection(.init(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        allowed.insert(charactersIn: "!#$&+-.^_`|~")
        return name + "*=utf-8''" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)
    }

    /// Quoted-printable lines (RFC 2045 §6.7): bytes outside printable ASCII and "=" as "=XX", a space
    /// or tab ending a line too, and soft line breaks ("=" at the end) keeping lines within 76.
    static func quotedPrintable(_ lines: [String]) -> String {
        lines.map { line in
            var out = "", length = 0
            let bytes = Array(line.utf8)
            for (index, byte) in bytes.enumerated() {
                let last = index == bytes.count - 1
                let piece = (byte >= 33 && byte <= 126 && byte != 61) || ((byte == 32 || byte == 9) && !last)
                    ? String(UnicodeScalar(byte)) : String(format: "=%02X", byte)
                // Room for the piece, and for "=" if more follows.
                if length + piece.count > (last ? 76 : 75) {
                    out += "=\r\n"
                    length = 0
                }
                out += piece
                length += piece.count
            }
            return out
        }.joined(separator: "\r\n")
    }

    // MARK: Headers

    /// "Name: value", folded at spaces to keep lines within 78; `encode` writes a value that isn't ASCII
    /// as encoded words.
    static func header(_ name: String, _ value: String, encode: Bool = false) -> String {
        let words = encode && !value.allSatisfy(\.isASCII)
            ? encodedWords(value, room: 75 - name.count - 2)
            : value.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        return fold(name + ":", words)
    }

    /// An address list, an address to a line where they don't fit on one.
    static func addressHeader(_ name: String, _ addresses: [EmailAddress]) -> String {
        let items = addresses.map(address)
        let line = name + ": " + items.joined(separator: ", ")
        guard line.count > 78, items.count > 1 else { return line }
        return name + ": " + items.joined(separator: ",\r\n ")
    }

    /// Message-IDs, in angle brackets, folded between them.
    static func idsHeader(_ name: String, _ ids: [String]) -> String {
        fold(name + ":", ids.map { "<" + $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) + ">" })
    }

    /// `Name <a@b>` (the name quoted, or encoded words, as it needs), else just the address.
    static func address(_ address: EmailAddress) -> String {
        let email = address.email ?? ""
        guard let name = address.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
            name.lowercased() != email.lowercased()
        else { return email }
        return phrase(name) + " <" + email + ">"
    }

    /// A display name as RFC 5322 has it: atoms as they are, a quoted string when it has specials,
    /// encoded words when it isn't ASCII.
    static func phrase(_ name: String) -> String {
        guard name.allSatisfy(\.isASCII) else { return encodedWords(name, room: 75).joined(separator: " ") }
        let atext = CharacterSet.alphanumerics.union(.init(charactersIn: "!#$%&'*+-/=?^_`{|}~ "))
        if name.unicodeScalars.allSatisfy({ $0.isASCII && atext.contains($0) }) { return name }
        return "\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Text as `=?utf-8?B?…?=` words of at most `room` characters each (75 at most), never splitting a
    /// character's bytes.
    static func encodedWords(_ text: String, room: Int = 75) -> [String] {
        let room = max(min(room, 75), 20)
        let payload = (room - "=?utf-8?B??=".count) / 4 * 3  // bytes per word
        var words: [String] = [], current = Data()
        for character in text {
            let bytes = Data(String(character).utf8)
            if !current.isEmpty, current.count + bytes.count > payload {
                words.append("=?utf-8?B?" + current.base64EncodedString() + "?=")
                current = Data()
            }
            current += bytes
        }
        if !current.isEmpty || words.isEmpty { words.append("=?utf-8?B?" + current.base64EncodedString() + "?=") }
        return words
    }

    /// `start` then the words, separated by spaces, a new (indented) line where the next wouldn't fit in 78.
    private static func fold(_ start: String, _ words: [String]) -> String {
        var out = start, length = start.count
        for word in words {
            if length + 1 + word.count > 78, length > start.count {
                out += "\r\n " + word
                length = 1 + word.count
            } else {
                out += " " + word
                length += 1 + word.count
            }
        }
        return out
    }

    /// RFC 5322's date: "Tue, 27 Oct 2026 11:40:00 +0100".
    static func dateText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return f.string(from: date)
    }
}
