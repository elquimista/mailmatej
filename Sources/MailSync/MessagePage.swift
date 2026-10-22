import Foundation

/// Builds the page the message view shows: the header fields and the remote-content bar ("chrome")
/// followed by the message content, so everything scrolls together as in MailMate.
///
/// The chrome uses custom element names (`mmj-*`), which email stylesheets don't target, and
/// `!important` styles, so an email's CSS can't restyle it. Its action links carry a per-page token,
/// so links inside an email can't trigger them.
public enum MessagePage {
    public static let actionScheme = "mmj-action"

    public enum Action: String, Sendable {
        case load, alwaysLoadMenu, stopAlwaysLoading
    }

    public struct HeaderField: Sendable {
        public var label: String
        public var value: String
        public var emphasized: Bool

        public init(label: String, value: String, emphasized: Bool = false) {
            self.label = label
            self.value = value
            self.emphasized = emphasized
        }
    }

    /// A file attached to the message, shown in the attachment row.
    public struct Attachment: Sendable {
        public var name: String
        public var size: String
        /// A `data:` URL of the file type's icon.
        public var icon: String

        public init(name: String, size: String, icon: String) {
            self.name = name
            self.size = size
            self.icon = icon
        }
    }

    /// A round button at the end of each attachment row (Quick Look, Save).
    public struct AttachmentButton: Sendable {
        /// Reported by the hit test as `<token>:<index>:<action>`.
        public var action: String
        public var title: String
        /// A `data:` URL of the 20 px button image.
        public var icon: String
        /// What the button shows while ⌥ is held (the app switches it), if it does something else then.
        public var optionTitle: String?
        public var optionIcon: String?

        public init(action: String, title: String, icon: String, optionTitle: String? = nil, optionIcon: String? = nil) {
            self.action = action
            self.title = title
            self.icon = icon
            self.optionTitle = optionTitle
            self.optionIcon = optionIcon
        }
    }

    public struct Bar: Sendable {
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
    }

    /// - Parameters:
    ///   - content: HTML for HTML messages, already-escaped text for plain ones.
    ///   - remote: whether https resources may load (only after the user allowed it).
    ///   - token: a random string identifying this page's action links.
    public static func html(
        headers: [HeaderField], attachments: [Attachment] = [], attachmentButtons: [AttachmentButton] = [], bar: Bar?,
        content: String, plain: Bool, remote: Bool, token: String
    ) -> String {
        // Plain text, and HTML that sets no colours of its own, follow dark mode as MailMate shows them.
        let adaptive = plain || (hasNoColors(content) && !hasPictures(content))
        let https = remote ? " https:" : ""
        let csp = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'\(https); "
            + "img-src data: \(MessageHTML.cidScheme):\(https); font-src data:\(https); media-src \(MessageHTML.cidScheme):"
        let colorScheme = adaptive ? #"<meta name="color-scheme" content="light dark">"# : ""
        return """
            <!doctype html><html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="\(csp)">\(colorScheme)
            <style>\(helveticaFaces)\(chromeCSS)\(plain ? plainCSS : htmlCSS)\(adaptive && !plain ? adaptiveCSS : "")</style>
            </head><body><mmj-chrome>\(headersHTML(headers))\(attachments.isEmpty && bar == nil ? "<mmj-sep class=\"body\"></mmj-sep>" : "<mmj-sep></mmj-sep>")\(attachmentsHTML(attachments, buttons: attachmentButtons, token: token))\(bar.map { barHTML($0, token: token) } ?? "")</mmj-chrome>\
            <mmj-content>\(content)</mmj-content></body></html>
            """
    }

    /// Script (run in the app's own script world) that shows the buttons' ⌥ variants while `option` is true.
    public static let optionKeyScript = """
        const chrome = document.querySelector('mmj-chrome');
        if (chrome) {
          if (option) { chrome.setAttribute('data-mmj-option', ''); } else { chrome.removeAttribute('data-mmj-option'); }
          for (const b of chrome.querySelectorAll('mmj-btn[data-mmj-option-title]')) {
            b.title = b.getAttribute(option ? 'data-mmj-option-title' : 'data-mmj-title');
          }
        }
        """

    /// Parses a clicked `mmj-action:<token>/<action>` link; nil if it isn't one of this page's.
    public static func action(from url: URL, token: String) -> Action? {
        guard url.scheme == actionScheme else { return nil }
        let parts = url.absoluteString.dropFirst(actionScheme.count + 1).split(separator: "/", maxSplits: 1)
        guard parts.count == 2, parts[0] == token else { return nil }
        return Action(rawValue: String(parts[1]))
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

    // MARK: Pieces

    static func headersHTML(_ fields: [HeaderField]) -> String {
        let rows = fields.filter { !$0.value.isEmpty }.map { f in
            "<mmj-label>\(escape(f.label))</mmj-label><mmj-value\(f.emphasized ? " class=\"em\"" : "")>\(escape(f.value))</mmj-value>"
        }
        return rows.isEmpty ? "" : "<mmj-headers>" + rows.joined() + "</mmj-headers>"
    }

    /// Each item carries `data-mmj-att="<token>:<index>"`; the app finds the item under the pointer by
    /// that attribute (in its own script world), so an email can't fake one without the page's token.
    static func attachmentsHTML(_ attachments: [Attachment], buttons: [AttachmentButton], token: String) -> String {
        guard !attachments.isEmpty else { return "" }
        let buttonsHTML = buttons.map { b in
            guard let optionTitle = b.optionTitle, let optionIcon = b.optionIcon else {
                return "<mmj-btn data-mmj-btn=\"\(escape(b.action))\" title=\"\(escape(b.title))\"><img src=\"\(b.icon)\" alt=\"\"></mmj-btn>"
            }
            return "<mmj-btn data-mmj-btn=\"\(escape(b.action))\" title=\"\(escape(b.title))\" data-mmj-title=\"\(escape(b.title))\" "
                + "data-mmj-option-title=\"\(escape(optionTitle))\"><img src=\"\(b.icon)\" alt=\"\">"
                + "<img class=\"option\" src=\"\(optionIcon)\" alt=\"\"></mmj-btn>"
        }.joined()
        let items = attachments.enumerated().map { index, a in
            "<mmj-att data-mmj-att=\"\(token):\(index)\"><img src=\"\(a.icon)\" alt=\"\">"
                + "<mmj-name title=\"\(escape(a.name))\">\(escape(a.name))</mmj-name><mmj-size>\(escape(a.size))</mmj-size>"
                + buttonsHTML + "</mmj-att>"
        }
        return "<mmj-attachments>" + items.joined() + "</mmj-attachments>"
    }

    static func barHTML(_ bar: Bar, token: String) -> String {
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        func button(_ title: String, _ action: Action) -> String {
            "<a href=\"\(actionScheme):\(token)/\(action.rawValue)\">\(escape(title))</a>"
        }
        let loadable = bar.remote - bar.strict
        let note = bar.strict > 0 ? " · \(plural(bar.strict, "tracker or insecure resource")) always blocked" : ""
        var buttons: [String] = []
        let text: String
        if bar.loaded {
            text = "Loaded \(plural(loadable, "remote resource"))\(note)"
            if !bar.allowedBy.isEmpty { buttons.append(button("Stop Always Loading", .stopAlwaysLoading)) }
        } else {
            text = "Blocked \(plural(bar.remote, "remote resource"))\(note)"
            if loadable > 0 {
                buttons.append(button("Load", .load))
                if bar.canAlwaysLoad { buttons.append(button("Always Load From ▾", .alwaysLoadMenu)) }
            }
        }
        return "<mmj-bar\(bar.loaded ? " class=\"loaded\"" : "")><mmj-text>\(escape(text))</mmj-text>"
            + "<mmj-spacer></mmj-spacer>" + buttons.joined() + "</mmj-bar>"
    }

    // MARK: Styles

    static let chromeCSS = """

        mmj-chrome { display: block !important; margin: 0 !important; padding: 0 !important; text-align: left !important;
          font: 13px/1.32 -apple-system, "Helvetica Neue", sans-serif !important; letter-spacing: normal !important;
          background: #F2F2F2 !important; color: #1D1D1F !important; border-bottom: 1px solid #D5D5D5 !important; }
        /* Email CSS can't reach the chrome's text: rules like `* { font-family: ... }` (Glassdoor) match these
           elements too. Each part inherits the chrome's font unless a more specific rule below sets its own. */
        mmj-chrome * { font-family: inherit !important; font-size: inherit !important; line-height: inherit !important;
          font-weight: inherit !important; font-style: inherit !important; letter-spacing: inherit !important;
          word-spacing: normal !important; text-transform: none !important; }
        mmj-headers { display: grid !important; grid-template-columns: max-content 1fr !important;
          column-gap: 8px !important; row-gap: 1px !important; padding: 8px 14px !important; }
        mmj-label { display: block !important; text-align: right !important; color: #86868B !important; }
        mmj-value { display: block !important; color: #1D1D1F !important; overflow-wrap: anywhere !important;
          -webkit-user-select: text !important; user-select: text !important; }
        mmj-value.em { font-weight: normal !important; }  /* MailMate shows the subject in regular weight. */
        /* As MailMate draws them (measured at 1x): a block darker than the headers with 5 px above and
           below, 23 px rows, every second row in a lighter box with 4 px corners inset 4 px (alternating
           rows, as in the lists); 20 px icon 15 px in, name, size, then 20 px round buttons 6 px apart,
           18 px from the right. */
        /* The line between the headers and the attachments: fades in from both sides, 8 px of header above
           and below it. */
        mmj-sep { display: block !important; height: 1px !important; margin: 0 0 8px !important;
          background: linear-gradient(to right, transparent, rgba(0,0,0,.25) 50%, transparent) !important; }
        /* With nothing between headers and body the same line closes the headers, on every message (MailMate);
           above attachments or the remote-content bar it keeps its 8 px gap. */
        /* 12 px below the last header's baseline, body text 29 px below it. Padding, not margin: a margin
           would collapse into the body's. */
        mmj-sep.body { margin: -1px 0 0 !important; padding-bottom: 2px !important; background-clip: content-box !important; }
        mmj-attachments { display: block !important; padding: 5px 4px !important; background: rgba(0,0,0,.05) !important; }
        mmj-att { display: flex !important; align-items: center !important; height: 23px !important;
          padding: 0 14px 0 11px !important; border-radius: 4px !important; cursor: default !important;
          -webkit-user-select: none !important; user-select: none !important; }
        mmj-att:nth-child(even) { background: rgba(0,0,0,.04) !important; }
        mmj-att > img { width: 20px !important; height: 20px !important; flex: none !important; margin-right: 5px !important; }
        mmj-name { display: block !important; flex: 1 !important; min-width: 0 !important; white-space: nowrap !important;
          overflow: hidden !important; text-overflow: ellipsis !important; color: #1D1D1F !important; }
        mmj-size { display: block !important; flex: none !important; margin: 0 8px 0 12px !important; color: #1D1D1F !important; }
        mmj-btn { display: block !important; flex: none !important; width: 20px !important; height: 20px !important;
          margin-left: 6px !important; }
        mmj-btn:first-of-type { margin-left: 0 !important; }
        mmj-btn img { display: block !important; width: 20px !important; height: 20px !important; }
        mmj-btn img.option, mmj-chrome[data-mmj-option] mmj-btn[data-mmj-option-title] img:not(.option) { display: none !important; }
        mmj-chrome[data-mmj-option] mmj-btn img.option { display: block !important; }
        mmj-btn:hover img { filter: brightness(1.25) !important; }
        mmj-btn:active img { filter: brightness(0.8) !important; }
        mmj-bar { display: flex !important; align-items: center !important; gap: 8px !important;
          padding: 5px 10px 5px 14px !important; background: #FF9F0A !important; color: #000 !important; }
        mmj-bar.loaded { background: #E8E8ED !important; color: #6E6E73 !important; }
        mmj-text { display: block !important; white-space: nowrap !important; overflow: hidden !important;
          text-overflow: ellipsis !important; }
        mmj-spacer { display: block !important; flex: 1 !important; }
        mmj-bar a { display: inline-block !important; white-space: nowrap !important; text-decoration: none !important;
          font: 11px/1.4 -apple-system, sans-serif !important; color: #1D1D1F !important; background: #FFF !important;
          border: 1px solid rgba(0,0,0,.25) !important; border-radius: 5px !important; padding: 1px 9px !important;
          cursor: default !important; }
        mmj-bar a:active { background: #E5E5E5 !important; }
        /* Dark: MailMate's colors as they show on screen (measured at 1x): headers (62,64,67), labels 146,
           values white, separator peaking at 212, attachments (42,46,49) with rows (55,59,61), text 227.
           WebKit renders CSS greys lighter on this display than AppKit draws the same values (CSS 43 shows
           as 56), so these are the CSS values that come out as those, from a rendered grey ladder. */
        @media (prefers-color-scheme: dark) {
          mmj-chrome { background: #303234 !important; color: #E5E5E7 !important; border-bottom: none !important; }
          mmj-label { color: #808080 !important; }
          mmj-value { color: #FFFFFF !important; }
          mmj-sep { background: linear-gradient(to right, transparent, #CACACA 50%, transparent) !important; }
          mmj-attachments { background: #202326 !important; }
          mmj-att:nth-child(even) { background: #2A2E2F !important; }
          mmj-name, mmj-size { color: #DEDEDE !important; }
          mmj-bar.loaded { background: #3A3A3C !important; color: #AEAEB2 !important; }
        }
        """

    static let htmlCSS = """

        /* The chrome must run edge to edge: emails often give <body> a margin, padding or width. */
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
    /// (fitted from a rendered colour ladder, see chromeCSS).
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
           (CSS values that render as those; see chromeCSS). */
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
