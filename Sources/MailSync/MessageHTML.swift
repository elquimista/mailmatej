import Foundation

/// URL patterns for remote content. Each is valid both as a WebKit content-rule `url-filter`
/// (a limited regex dialect: no `|`, no groups) and as an `NSRegularExpression`, so the counts
/// shown to the user and the rules that do the blocking come from one list.
public enum RemoteContentRules {
    /// Everything that would reach the network.
    public static let remotePatterns = ["^https?:", "^wss?:", "^ftp:"]

    /// Never loaded, even when the user loads remote content: insecure transports and known
    /// open-tracking endpoints. Best effort; 1×1 and hidden images are caught in the HTML instead.
    public static let strictPatterns = [
        "^http:", "^wss?:", "^ftp:",
        "/track/open",  // Mailchimp
        "/wf/open",  // SendGrid
        "/__ptq\\.gif",  // HubSpot
        "/open\\.php", "/open\\.aspx",
        "/pixel\\.gif", "/pixel\\.png", "/beacon\\.gif",
        "^https?://[^/]*google-analytics\\.com",
        "^https?://[^/]*doubleclick\\.net",
        "^https?://[^/]*mixpanel\\.com/track",
        "^https?://[^/]*mailtrack\\.io",
        "^https?://[^/]*mailfoogae\\.appspot\\.com",  // Streak
        "^https?://[^/]*bananatag\\.com",
        "^https?://[^/]*yesware\\.com",
        "^https?://[^/]*getnotify\\.com",
        "^https?://[^/]*mailsuite\\.com",
    ]

    /// A WebKit content-rule list blocking every URL that matches one of `patterns`.
    public static func contentRuleListJSON(_ patterns: [String]) -> String {
        let rules = patterns.map { pattern -> [String: Any] in
            ["trigger": ["url-filter": pattern, "url-filter-is-case-sensitive": false], "action": ["type": "block"]]
        }
        let data = try! JSONSerialization.data(withJSONObject: rules, options: [.withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static let strictRegexes = strictPatterns.map { try! NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    public static func isStrict(_ url: String) -> Bool {
        let range = NSRange(url.startIndex..., in: url)
        return strictRegexes.contains { $0.firstMatch(in: url, range: range) != nil }
    }
}

/// HTML ready to display, plus what was found in it.
public struct PreparedHTML: Sendable, Equatable {
    public var html: String
    /// Distinct remote resources referenced (images, stylesheets, fonts, ...), including strict ones.
    public var remoteCount: Int
    /// Of those, the ones that are never loaded.
    public var strictCount: Int
}

public enum MessageHTML {
    /// Embedded parts are served as `mmj-cid://<messageId>/<content-id>`.
    public static let cidScheme = "mmj-cid"

    /// - Parameter blockRemote: whether remote images will be blocked. Blocked images are replaced by
    ///   a crossed placeholder box at their declared size; strictly blocked ones always are.
    public static func prepare(_ html: String, messageId: Int64, blockRemote: Bool = true) -> PreparedHTML {
        let withCIDs = rewriteCIDs(pinGenericSansSerif(html), messageId: messageId)
        let remote = remoteURLs(in: withCIDs)
        var pixels = Set<String>()
        let output = replaceRemoteImages(withCIDs, blockRemote: blockRemote, pixels: &pixels)
        let all = remote.union(pixels)
        let strict = pixels.union(all.filter(RemoteContentRules.isStrict))
        return PreparedHTML(html: output, remoteCount: all.count, strictCount: strict.count)
    }

    /// A yellow outlined box with an X (as MailMate draws blocked images), with the image's alt text
    /// in the corner. The SVG has no viewBox, so the box fills whatever size the `<img>` has while
    /// the text keeps its normal size.
    public static func blockedImagePlaceholder(alt: String) -> String {
        let text = alt.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = text.isEmpty ? "" : """
            <text x="4" y="13" font-family="Helvetica, Arial, sans-serif" font-size="11" fill="#5C4B00" \
            stroke="#FFFFFF" stroke-width="3" stroke-linejoin="round" paint-order="stroke">\(xmlEscape(text))</text>
            """
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" width="100%" height="100%">\
            <g fill="none" stroke="#F5C400"><rect x="0" y="0" width="100%" height="100%" stroke-width="2"/>\
            <line x1="0" y1="0" x2="100%" y2="100%" stroke-width="1.5"/>\
            <line x1="100%" y1="0" x2="0" y2="100%" stroke-width="1.5"/></g>\(label)</svg>
            """
        return "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()
    }

    /// The size given to a blocked image that doesn't declare one: room for its alt text, or 40×40.
    static func placeholderSize(alt: String) -> (width: Int, height: Int) {
        let text = alt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return (40, 40) }
        return (min(300, max(40, Int(Double(text.count) * 6.5) + 10)), 20)
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Decodes the few entities common in attribute values.
    static func htmlUnescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: Fonts

    /// Puts `Helvetica` in front of the generic `sans-serif` in CSS (style attributes, `<style>` blocks,
    /// `<font face>`). In WebKit inside an app, bold `sans-serif` falls back to a synthesized bold that
    /// looks heavy; the message page maps `Helvetica` to its real faces, so this keeps bold text crisp.
    static func pinGenericSansSerif(_ html: String) -> String {
        func pin(_ css: String) -> String {
            replace(#"(?i)(?<![\w-])sans-serif(?![\w-])"#, in: css) { _ in "Helvetica, sans-serif" }
        }
        var out = replace(#"(?is)(<style\b[^>]*>)(.*?)(</style>)"#, in: html) { m in m[1] + pin(m[2]) + m[3] }
        out = replace(#"(?i)(\s(?:style|face)\s*=\s*)("[^"]*"|'[^']*')"#, in: out) { m in m[1] + pin(m[2]) }
        return out
    }

    // MARK: Embedded images

    static func rewriteCIDs(_ html: String, messageId: Int64) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return replace(#"(?i)\bcid:([^"'\s)>]+)"#, in: html) { match in
            let cid = match[1].removingPercentEncoding ?? match[1]
            return "\(cidScheme)://\(messageId)/" + (cid.addingPercentEncoding(withAllowedCharacters: allowed) ?? cid)
        }
    }

    // MARK: Remote resources

    static func remoteURLs(in html: String) -> Set<String> {
        var urls = Set<String>()
        let remote = #"(?:https?|ftp|wss?):[^"'\s>)]+"#
        for pattern in [
            #"(?i)\b(?:src|background|poster|data)\s*=\s*["']?\s*("# + remote + ")",
            #"(?i)<link\b[^>]*\bhref\s*=\s*["']?\s*("# + remote + ")",
            #"(?i)url\(\s*["']?\s*("# + remote + ")",
            #"(?i)@import\s+["']("# + remote + ")",
        ] {
            for match in matches(pattern, in: html) { urls.insert(match[1]) }
        }
        for match in matches(#"(?i)\bsrcset\s*=\s*["']([^"']*)["']"#, in: html) {
            for candidate in match[1].split(separator: ",") {
                if let url = candidate.split(whereSeparator: \.isWhitespace).first, url.contains("://") {
                    urls.insert(String(url))
                }
            }
        }
        return urls
    }

    /// Rewrites remote `<img>` sources. Hidden or 0–1 px images (classic open-tracking pixels) get an
    /// empty image and are recorded in `pixels`. Other remote images get the placeholder box when
    /// blocked (always, if strictly blocked), with the original URL as a tooltip.
    static func replaceRemoteImages(_ html: String, blockRemote: Bool, pixels: inout Set<String>) -> String {
        var found = Set<String>()
        let result = replace(#"(?i)<img\b[^>]*>"#, in: html) { match in
            var tag = match[0]
            guard let src = matches(#"(?i)\bsrc\s*=\s*["']?\s*((?:https?|ftp):[^"'\s>]+)"#, in: tag).first?[1] else {
                return tag
            }
            if isTrackingPixel(tag) {
                found.insert(src)
                return tag.replacingOccurrences(of: src, with: "data:,")
            }
            guard blockRemote || RemoteContentRules.isStrict(src) else { return tag }
            let alt = htmlUnescape(matches(#"(?i)\balt\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#, in: tag).first
                .map { $0[1] + $0[2] + $0[3] } ?? "")
            tag = replace(#"(?i)\s+srcset\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#, in: tag) { _ in "" }
            tag = tag.replacingOccurrences(of: src, with: blockedImagePlaceholder(alt: alt))
            var extra = "data-mmj-blocked title=\"Blocked: \(src.replacingOccurrences(of: "\"", with: "&quot;"))\""
            let style = matches(#"(?i)\bstyle\s*=\s*["']([^"']*)["']"#, in: tag).first?[1] ?? ""
            let size = placeholderSize(alt: alt)
            if matches(#"(?i)\swidth\s*="#, in: tag).isEmpty && matches(#"(?i)(^|[;\s])width\s*:"#, in: style).isEmpty {
                extra += " width=\"\(size.width)\""
            }
            if matches(#"(?i)\sheight\s*="#, in: tag).isEmpty && matches(#"(?i)(^|[;\s])height\s*:"#, in: style).isEmpty {
                extra += " height=\"\(size.height)\""
            }
            return tag.replacingOccurrences(of: #"(?i)^<img\b"#, with: "<img \(extra)", options: .regularExpression)
        }
        pixels.formUnion(found)
        return result
    }

    static func isTrackingPixel(_ tag: String) -> Bool {
        let tiny = #"\s*=\s*["']?\s*[01](?:px)?\s*(?:["'\s/>])"#
        if !matches(#"(?i)\bwidth"# + tiny, in: tag).isEmpty && !matches(#"(?i)\bheight"# + tiny, in: tag).isEmpty {
            return true
        }
        if let style = matches(#"(?i)\bstyle\s*=\s*["']([^"']*)["']"#, in: tag).first?[1] {
            if !matches(#"(?i)display\s*:\s*none|visibility\s*:\s*hidden"#, in: style).isEmpty { return true }
            if !matches(#"(?i)\bwidth\s*:\s*[01]px"#, in: style).isEmpty
                && !matches(#"(?i)\bheight\s*:\s*[01]px"#, in: style).isEmpty
            {
                return true
            }
        }
        return false
    }

    // MARK: Regex helpers

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { m in
            (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: text).map { String(text[$0]) } ?? "" }
        }
    }

    private static func replace(_ pattern: String, in text: String, with transform: ([String]) -> String) -> String {
        let regex = try! NSRegularExpression(pattern: pattern)
        var result = ""
        var last = text.startIndex
        for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(m.range, in: text) else { continue }
            let groups = (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: text).map { String(text[$0]) } ?? "" }
            result += text[last..<range.lowerBound] + transform(groups)
            last = range.upperBound
        }
        return result + text[last...]
    }
}
