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

    public static func prepare(_ html: String, messageId: Int64) -> PreparedHTML {
        var strict = Set<String>()
        var output = neutralizeTrackingPixels(html, strict: &strict)
        output = rewriteCIDs(output, messageId: messageId)
        let remote = remoteURLs(in: output).union(strict)
        strict.formUnion(remote.filter(RemoteContentRules.isStrict))
        return PreparedHTML(html: output, remoteCount: remote.count, strictCount: strict.count)
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

    /// Replaces the `src` of remote images that are 0–1 px or hidden (classic open-tracking pixels)
    /// with an empty image, recording their URLs as strictly blocked.
    static func neutralizeTrackingPixels(_ html: String, strict: inout Set<String>) -> String {
        var found = Set<String>()
        let result = replace(#"(?i)<img\b[^>]*>"#, in: html) { match in
            let tag = match[0]
            guard isTrackingPixel(tag),
                let src = matches(#"(?i)\bsrc\s*=\s*["']?\s*((?:https?|ftp):[^"'\s>]+)"#, in: tag).first?[1]
            else { return tag }
            found.insert(src)
            return tag.replacingOccurrences(of: src, with: "data:,")
        }
        strict.formUnion(found)
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
