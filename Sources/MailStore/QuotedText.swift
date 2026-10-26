import Foundation

/// A message's text split as MailMate's Unquoted Text and Quoted Text conditions see it: what the
/// sender wrote, and what their reply quotes ("> " lines in plain text, blockquotes in HTML). The
/// attribution line before a quote ("On …, … wrote:") is the sender's own text.
public enum QuotedText {
    public struct Split: Equatable, Sendable {
        /// The whole text, as plain text.
        public var all: String
        public var unquoted: String
        public var quoted: String
    }

    /// The plain text when there is one (its "> " lines are reliable), else the HTML's.
    public static func split(text: String?, html: String?) -> Split {
        if let text, !text.isEmpty { return split(plain: text) }
        if let html { return split(html: html) }
        return Split(all: "", unquoted: "", quoted: "")
    }

    public static func split(plain text: String) -> Split {
        var unquoted: [Substring] = [], quoted: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.drop(while: { $0 == " " }).hasPrefix(">") {
                quoted.append(line.drop { $0 == " " || $0 == ">" })
            } else {
                unquoted.append(line)
            }
        }
        return Split(all: text, unquoted: unquoted.joined(separator: "\n"), quoted: quoted.joined(separator: "\n"))
    }

    /// Blockquotes (nested ones within the outermost) are the quote; the rest is the sender's.
    public static func split(html: String) -> Split {
        var unquoted = "", quoted = ""
        var depth = 0
        var rest = html[...]
        while let tag = rest.range(of: #"(?i)</?blockquote\b[^>]*>"#, options: .regularExpression) {
            let before = rest[..<tag.lowerBound]
            if depth == 0 { unquoted += before } else { quoted += before }
            if rest[tag].hasPrefix("</") { depth = max(0, depth - 1) } else { depth += 1 }
            if depth > 0 { quoted += " " } else { unquoted += " " }
            rest = rest[tag.upperBound...]
        }
        if depth == 0 { unquoted += rest } else { quoted += rest }
        return Split(all: plainText(html), unquoted: plainText(unquoted), quoted: plainText(quoted))
    }

    /// HTML's readable text (for searching): without styles and scripts, tags as spaces or line breaks.
    static func plainText(_ html: String) -> String {
        var s = html.replacingOccurrences(of: #"(?is)<(style|script|head|title)\b.*?</\1>"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)<(br|/p|/div|/tr|/li|/h\d)\b[^>]*>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        for (entity, char) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        s = s.replacingOccurrences(of: #"[ \t\r\f]+"#, with: " ", options: .regularExpression)
        return s.replacingOccurrences(of: #"\s*\n\s*"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
