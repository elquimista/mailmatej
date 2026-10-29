import Foundation

/// Builds the page the message view shows: the message content alone. The header fields, attachments
/// and remote-content bar are native views above it (see MessageHeaderView), so an email's CSS can't
/// touch them; the page ends with an `<mmj-end>` marker the app measures the content's height by.
public enum MessagePage {
    /// What the remote-content bar offers.
    public enum Action: String, Sendable {
        case load, alwaysLoadMenu, stopAlwaysLoading
    }

    public struct Bar: Sendable, Equatable {
        public var remote: Int
        public var strict: Int
        public var loaded: Bool
        public var canAlwaysLoad: Bool
        public var allowedBy: [String]

        public init(remote: Int, strict: Int, loaded: Bool, canAlwaysLoad: Bool, allowedBy: [String]) {
            self.remote = remote
            self.strict = strict
            self.loaded = loaded
            self.canAlwaysLoad = canAlwaysLoad
            self.allowedBy = allowedBy
        }

        /// "Blocked 5 remote resources · 2 tracker or insecure resources always blocked".
        public var text: String {
            func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
            let note = strict > 0 ? " · \(plural(strict, "tracker or insecure resource")) always blocked" : ""
            return loaded ? "Loaded \(plural(remote - strict, "remote resource"))\(note)" : "Blocked \(plural(remote, "remote resource"))\(note)"
        }

        /// The bar's buttons, in order, with their titles.
        public var actions: [(title: String, action: Action)] {
            if loaded { return allowedBy.isEmpty ? [] : [("Stop Always Loading", .stopAlwaysLoading)] }
            guard remote - strict > 0 else { return [] }
            return [("Load", .load)] + (canAlwaysLoad ? [("Always Load From ▾", .alwaysLoadMenu)] : [])
        }
    }

    /// - Parameters:
    ///   - content: HTML for HTML messages, already-escaped text for plain ones.
    ///   - remote: whether https resources may load (only after the user allowed it).
    public static func html(content: String, plain: Bool, remote: Bool) -> String {
        // Plain text, and HTML that sets no colours of its own, follow dark mode as MailMate shows them.
        let adaptive = plain || (hasNoColors(content) && !hasPictures(content))
        let https = remote ? " https:" : ""
        let csp = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'\(https); "
            + "img-src data: \(MessageHTML.cidScheme):\(https); font-src data:\(https); media-src \(MessageHTML.cidScheme):"
        let colorScheme = adaptive ? #"<meta name="color-scheme" content="light dark">"# : ""
        return """
            <!doctype html><html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="\(csp)">\(colorScheme)
            <style>\(helveticaFaces)\(pageCSS)\(plain ? plainCSS : htmlCSS)\(adaptive && !plain ? adaptiveCSS : "")</style>
            </head><body><mmj-content>\(content)</mmj-content><mmj-end></mmj-end></body></html>
            """
    }

    /// Whether HTML shows a picture (an image not declared 1 or 2 px wide or tall, which a tracking pixel
    /// is). MailMate keeps such HTML on white even without colours: pictures, often on white themselves,
    /// look wrong on a dark page. (Seen at 1x: a Markdown message with an embedded picture stays white,
    /// one whose only image is a tracking pixel goes dark.)
    static func hasPictures(_ html: String) -> Bool {
        var rest = html[...]
        while let tag = rest.range(of: #"<img\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            let img = String(rest[tag])
            let tiny = img.range(of: #"(?i)\b(width|height)\s*=\s*["']?\s*[0-2](px)?\s*["'\s/>]"#, options: .regularExpression) != nil
                || img.range(of: #"(?i)(width|height)\s*:\s*[0-2](px)?\s*[;"']"#, options: .regularExpression) != nil
            if !tiny { return true }
            rest = rest[tag.upperBound...]
        }
        return false
    }

    /// Whether HTML leaves all colours to the reader, so it can be shown light-on-dark as MailMate does.
    /// Any colour counts, as in MailMate: colour, background or bgcolor, but also a colour value in any
    /// other style (Gmail's quote bar, `border-left: 1px solid rgb(204,204,204)`, keeps a reply on white).
    static func hasNoColors(_ html: String) -> Bool {
        html.range(of: colorPattern, options: .regularExpression) == nil
    }

    private static let namedColors =
        "black|white|gr[ae]y|silver|red|maroon|blue|navy|green|lime|olive|teal|aqua|cyan|yellow|orange|purple|fuchsia|"
        + "magenta|pink|brown|gold|beige|ivory|indigo|violet|crimson|coral|salmon|khaki|tan|lavender|turquoise|"
        + "(?:light|dark|dim|slate|steel|royal|sky|dodger|cornflower|midnight|forest|sea|hot|deep)[a-z]+"
    private static let colorPattern =
        #"(?i)(color|background)\s*[:=]|bgcolor|<body[^>]*\btext\s*="#
        // A colour value in a style declaration (a property name, then no "/", so not a URL): rgb(), hsl()
        // and the like, or a hex code.
        + #"|[a-z-]+\s*:[^;"'{}<>/]*\b(?:rgba?|hsla?|hwb|lab|lch|oklab|oklch)\s*\("#
        + #"|[a-z-]+\s*:[^;"'{}<>/]*#[0-9a-f]{3,8}\b"#
        // A named colour in a border, outline, shadow, underline or SVG paint.
        + #"|(?:border|outline|shadow|decoration|column-rule|fill|stroke)[a-z-]*\s*:[^;"'{}<>]*\b(?:"#
        + namedColors + #")\b"#

    /// A plain-text body as HTML: one block per line, and runs of quoted lines ("> ...") as quote blocks
    /// with the markers removed, nested per level, as MailMate shows them.
    public static func plainHTML(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        return plainBlocks(lines)
    }

    private static func plainBlocks(_ lines: [String]) -> String {
        var html = ""
        var index = 0
        while index < lines.count {
            if lines[index].hasPrefix(">") {
                var quoted: [String] = []
                while index < lines.count, lines[index].hasPrefix(">") {
                    var line = lines[index].dropFirst()
                    if line.hasPrefix(" ") { line = line.dropFirst() }
                    quoted.append(String(line))
                    index += 1
                }
                html += "<mmj-quote>" + plainBlocks(quoted) + "</mmj-quote>"
            } else {
                let line = lines[index]
                html += "<mmj-line>" + (line.isEmpty ? "<br>" : escape(line)) + "</mmj-line>"
                index += 1
            }
        }
        return html
    }

    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: Styles

    /// The page as a whole: the native scroll view above it scrolls it (the page never scrolls up and
    /// down itself; wide content still scrolls sideways), and the end marker sits right after the content.
    static let pageCSS = """

        html { overflow-y: hidden !important; }
        mmj-end { display: block !important; clear: both !important; height: 0 !important; margin: 0 !important;
          padding: 0 !important; border: 0 !important; position: static !important; }
        /* What the search finds, as MailMate marks it: black on grey (170 on screen), light or dark. */
        mmj-mark { background-color: #aaa !important; color: #000 !important; }
        /* Find's current match (Edit ▸ Find), MailMate's yellow. */
        mmj-mark[current] { background-color: #ff0 !important; }
        """

    static let htmlCSS = """

        /* The content runs edge to edge under the headers: emails often give <body> a margin, padding or width. */
        html, body { margin: 0 !important; padding: 0 !important; border: 0 !important;
          width: auto !important; min-width: 0 !important; max-width: none !important; }
        /* Emails that set no font get MailMate's: the system font at 13 px (measured: SF 13, 16 px lines). */
        mmj-content { display: block; margin: 14px; font: 13px -apple-system, sans-serif;
          overflow-wrap: break-word; }
        img[data-mmj-blocked] { object-fit: fill !important; }
        .status { font: 13px -apple-system, sans-serif; color: GrayText; }
        """

    /// Dark mode for HTML without colours: the plain-text page's background (see plainCSS), and
    /// MailMate's link blue.
    static let adaptiveCSS = """

        @media (prefers-color-scheme: dark) {
          html, body { background: #303234 !important; }
          a:link, a:visited { color: \(darkLinkColor); }
        }
        """

    /// MailMate's links on a dark page show as (70,150,207) at 1x; this CSS colour comes out as that
    /// (fitted from a rendered colour ladder: WebKit draws colours lighter on this display).
    static let darkLinkColor = "rgb(57, 131, 196)"

    static let plainCSS = """

        html, body { margin: 0 !important; padding: 0 !important; }
        mmj-content { display: block; margin: 14px; font: 13px/16px -apple-system, sans-serif; white-space: pre-wrap;
          overflow-wrap: anywhere; }
        mmj-line { display: block; }
        /* MailMate: a 2 pt bar at the text's left edge, the quote 7 pt in, bar and text grey. */
        mmj-quote { display: block; border-left: 2px solid #A0A0A0; padding-left: 5px; color: #808080; }
        .status { color: GrayText; }
        /* Dark: MailMate shows plain text on the header grey (62,64,67 on screen), quotes and bar at 138
           (CSS values that render as those, from a rendered grey ladder). */
        @media (prefers-color-scheme: dark) {
          html, body { background: #303234 !important; }
          mmj-quote { border-left-color: #787878; color: #787878; }
          a:link, a:visited { color: \(darkLinkColor); }
        }
        """

    /// In an app's WebKit process, `font-family: Helvetica` at bold weight doesn't find Helvetica's
    /// bold face and WebKit fakes bold by thickening the regular face, which looks heavy and rough
    /// (about 6% wider than MailMate on a 1x display). Naming the faces explicitly avoids that.
    static let helveticaFaces: String = {
        let faces: [(weight: String, style: String, names: [String])] = [
            ("100 399", "normal", ["Helvetica-Light", "Helvetica Light"]),
            ("400 599", "normal", ["Helvetica", "Helvetica Regular"]),
            ("600 900", "normal", ["Helvetica-Bold", "Helvetica Bold"]),
            ("100 399", "italic", ["Helvetica-LightOblique", "Helvetica Light Oblique"]),
            ("400 599", "italic", ["Helvetica-Oblique", "Helvetica Oblique"]),
            ("600 900", "italic", ["Helvetica-BoldOblique", "Helvetica Bold Oblique"]),
        ]
        return faces.map { f in
            let src = f.names.map { "local(\"\($0)\")" }.joined(separator: ", ")
            return "\n@font-face { font-family: \"Helvetica\"; font-weight: \(f.weight); font-style: \(f.style); src: \(src); }"
        }.joined()
    }()
}
