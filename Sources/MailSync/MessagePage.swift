import Foundation

/// Builds the page the message view shows: the message content alone. The header fields, attachments
/// and remote-content bar are native views above it (see MessageHeaderView), so an email's CSS can't
/// touch them; the page ends with an `<mmj-end>` marker the app measures the content's height by.
public enum MessagePage {
    /// What the remote-content bar offers.
    public enum Action: String, Sendable {
        case load, reload
    }

    /// The remote-content bar, MailMate's: what the message's external resources are and what's blocked.
    /// Strictly blocked ones (trackers, insecure connections, tracking pixels) are never loaded.
    public struct Bar: Sendable, Equatable {
        public var resources: [RemoteResource]
        public var loaded: Bool
        /// Images that turned out 1 by 1 pixel once loaded (open trackers the HTML didn't give away).
        public var downloadedPixels: Int

        public init(resources: [RemoteResource], loaded: Bool, downloadedPixels: Int = 0) {
            self.resources = resources
            self.loaded = loaded
            self.downloadedPixels = downloadedPixels
        }

        public var remote: Int { resources.count }
        public var strict: Int { resources.filter { $0.strictType != nil }.count }

        /// MailMate's colours by risk: yellow for external resources, orange when some are strictly
        /// blocked, red once a 1 by 1 image has been downloaded.
        public enum Level: Sendable { case yellow, orange, red }

        public var level: Level {
            if loaded, downloadedPixels > 0 { return .red }
            return strict > 0 ? .orange : .yellow
        }

        /// MailMate's: "Detected 4 external resources of which 1 is strictly blocked", "An image with a
        /// pixel size of 1 by 1 has been downloaded".
        public var text: String {
            func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
            switch level {
            case .red:
                return downloadedPixels == 1
                    ? "An image with a pixel size of 1 by 1 has been downloaded"
                    : "\(downloadedPixels) images with a pixel size of 1 by 1 have been downloaded"
            case .yellow, .orange:
                let which = strict > 0 ? " of which \(strict) \(strict == 1 ? "is" : "are") strictly blocked" : ""
                return "Detected \(plural(remote, "external resource"))\(which)"
            }
        }

        /// The bar's buttons, in order, with their titles: Download (what isn't strictly blocked), then
        /// once downloaded, Reload (the message as it first showed, blocked again).
        public var actions: [(title: String, action: Action)] {
            guard loaded else { return remote - strict > 0 ? [("Download (\(remote - strict))", .load)] : [] }
            return [("Reload", .reload)]
        }

        /// The details MailMate shows under the bar, row by row: the risk, then what's strictly blocked
        /// (by type) and what's blocked (or downloaded), each resource with what refers to it.
        public var details: [(label: String, lines: [String])] {
            func line(_ r: RemoteResource) -> String { "\(r.url) (\(r.kind))" }
            var rows = [("Risk analysis", ["Downloading external resources can reveal to the sender if, when, and where the email was opened."])]
            if strict > 0 {
                let types = RemoteResource.StrictType.allCases.filter { type in resources.contains { $0.strictType == type } }
                rows.append(("Strictly blocked (\(strict))", types.flatMap { type in
                    ["Type: \(type.rawValue)"] + resources.filter { $0.strictType == type }.map(line)
                }))
            }
            let others = resources.filter { $0.strictType == nil }
            if !others.isEmpty { rows.append(("\(loaded ? "Downloaded" : "Blocked") (\(others.count))", others.map(line))) }
            return rows
        }
    }

    /// - Parameters:
    ///   - content: HTML for HTML messages, already-escaped text for plain ones.
    ///   - remote: whether https resources may load (only after the user allowed it).
    public static func html(content: String, plain: Bool, remote: Bool) -> String {
        html(content: content, plain: plain, remote: remote, adaptive: adapts(content, plain: plain))
    }

    /// Whether a message's page follows dark mode: plain text, and HTML that sets no colours of its own,
    /// as MailMate shows them. The others show light, so their web view is light too: HTML's own dark
    /// mode (prefers-color-scheme) would make its text white on its white (as Gmail's web app, which
    /// drops those rules, doesn't).
    public static func adapts(_ content: String, plain: Bool) -> Bool {
        plain || (hasNoColors(content) && !hasPictures(content))
    }

    /// `html(content:plain:remote:)`, with `adapts` already known. `stacked`: the page is one of several
    /// messages shown together (see `MessageStackPage`), in a frame of a page that follows dark mode.
    public static func html(content: String, plain: Bool, remote: Bool, adaptive: Bool, stacked: Bool = false) -> String {
        let colorScheme = adaptive ? #"<meta name="color-scheme" content="light dark">"# : ""
        // In a stack the page can't be made light by its web view: a light-only one keeps its light rules
        // whatever the appearance (see `lightOnly`), on white.
        let content = stacked && !adaptive ? lightOnly(content) : content
        let stackCSS = stacked ? stackedCSS + (adaptive ? "" : lightOnlyCSS) : ""
        return """
            <!doctype html><html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="\(csp(remote: remote))">\(colorScheme)
            <style>\(helveticaFaces)\(pageCSS)\(plain ? plainCSS : htmlCSS)\(adaptive && !plain ? adaptiveCSS : "")\(stackCSS)</style>
            </head><body><mmj-content>\(content)</mmj-content><mmj-end></mmj-end></body></html>
            """
    }

    /// The page's policy: no scripts, nothing remote unless `remote` (then https only).
    public static func csp(remote: Bool) -> String {
        let https = remote ? " https:" : ""
        return "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'\(https); "
            + "img-src data: \(MessageHTML.cidScheme):\(https); font-src data:\(https); media-src \(MessageHTML.cidScheme):"
    }

    /// An email's dark-mode rules made never to apply, and its light-mode ones always: a frame follows its
    /// web view's appearance whatever its own `color-scheme`, so a light-only email in a dark stack would
    /// otherwise switch to its dark styles (white text on its own white). Media queries keep their logic:
    /// `(prefers-color-scheme: dark)` becomes `(max-width: 0px)`, never true of a frame on screen.
    public static func lightOnly(_ html: String) -> String {
        html.replacingOccurrences(of: #"(?i)prefers-color-scheme\s*:\s*dark"#, with: "max-width: 0px", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)prefers-color-scheme\s*:\s*light"#, with: "min-width: 0px", options: .regularExpression)
    }

    /// MailMate's stacked messages have their text 8 px in (its single message's, 14).
    static let stackedCSS = """

        mmj-content { margin: 8px !important; }
        """

    /// A light-only email in a stack: light defaults (black text, white canvas) whatever the appearance.
    static let lightOnlyCSS = """

        :root { color-scheme: light only !important; }
        html { background: #fff; }
        """

    /// A message's raw source, as MailMate's Show Raw Message shows it: as it came (UTF-8, else Latin-1
    /// byte for byte), in a framed block of fixed-width text, long lines wrapped. Nothing in it loads.
    public static func rawHTML(_ source: Data) -> String {
        // Escaping only touches ASCII, so the escaped bytes are UTF-8 exactly when the source is.
        let text = String(bytes: rawEscaped(source), encoding: .utf8)
            ?? String(decoding: rawEscaped(Data((String(data: source, encoding: .isoLatin1) ?? "").utf8)), as: UTF8.self)
        return """
            <!doctype html><html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
            <meta name="color-scheme" content="light dark">
            <style>\(pageCSS)\(rawCSS)</style>
            </head><body><mmj-content>\(text)</mmj-content><mmj-end></mmj-end></body></html>
            """
    }

    /// The source's bytes escaped as `escape` does, CRLF line ends as LF, in one pass: a message with
    /// attachments runs to megabytes (4 MB: 6 ms, against 64 for `replacingOccurrences` pass by pass).
    static func rawEscaped(_ source: Data) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(source.count + source.count / 32)
        source.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            let count = bytes.count
            for i in 0..<count {
                let byte = bytes[i]
                switch byte {
                case 0x0D where i + 1 < count && bytes[i + 1] == 0x0A: continue
                case UInt8(ascii: "&"): out.append(contentsOf: "&amp;".utf8)
                case UInt8(ascii: "<"): out.append(contentsOf: "&lt;".utf8)
                case UInt8(ascii: ">"): out.append(contentsOf: "&gt;".utf8)
                case UInt8(ascii: "\""): out.append(contentsOf: "&quot;".utf8)
                default: out.append(byte)
                }
            }
        }
        return out
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

    /// The raw source: fixed-width text in a framed block. Provisional values, from MailMate's screen
    /// at a glance (11 px Menlo-width characters, 15 px lines); to be measured.
    static let rawCSS = """

        html, body { margin: 0 !important; padding: 0 !important; }
        mmj-content { display: block; margin: 10px; padding: 6px; border: 1px solid #b4b4b4;
          font: 11px/15px Menlo, monospace; white-space: pre-wrap; overflow-wrap: anywhere; }
        @media (prefers-color-scheme: dark) {
          html, body { background: #303234 !important; }
          mmj-content { border-color: #5a5a5a; }
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
