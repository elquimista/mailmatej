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
        let https = remote ? " https:" : ""
        let csp = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'\(https); "
            + "img-src data: \(MessageHTML.cidScheme):\(https); font-src data:\(https); media-src \(MessageHTML.cidScheme):"
        let colorScheme = plain ? #"<meta name="color-scheme" content="light dark">"# : ""
        return """
            <!doctype html><html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="\(csp)">\(colorScheme)
            <style>\(helveticaFaces)\(chromeCSS)\(plain ? plainCSS : htmlCSS)</style>
            </head><body><mmj-chrome>\(headersHTML(headers))\(attachmentsHTML(attachments, buttons: attachmentButtons, token: token))\(bar.map { barHTML($0, token: token) } ?? "")</mmj-chrome>\
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
        @media (prefers-color-scheme: dark) {
          mmj-chrome { background: #2B2B2D !important; color: #E5E5E7 !important; border-bottom-color: #3D3D40 !important; }
          mmj-label { color: #98989D !important; }
          mmj-value { color: #F2F2F7 !important; }
          mmj-attachments { background: rgba(0,0,0,.33) !important; }
          mmj-att:nth-child(even) { background: rgba(255,255,255,.045) !important; }
          mmj-name, mmj-size { color: #E3E3E3 !important; }
          mmj-bar.loaded { background: #3A3A3C !important; color: #AEAEB2 !important; }
        }
        """

    static let htmlCSS = """

        /* The chrome must run edge to edge: emails often give <body> a margin, padding or width. */
        html, body { margin: 0 !important; padding: 0 !important; border: 0 !important;
          width: auto !important; min-width: 0 !important; max-width: none !important; }
        mmj-content { display: block; margin: 14px; font-family: Helvetica, Arial, sans-serif; font-size: 14px;
          overflow-wrap: break-word; }
        img[data-mmj-blocked] { object-fit: fill !important; }
        .status { font: 13px -apple-system, sans-serif; color: GrayText; }
        """

    static let plainCSS = """

        html, body { margin: 0 !important; padding: 0 !important; }
        mmj-content { display: block; margin: 14px; font: 13px -apple-system, sans-serif; white-space: pre-wrap;
          overflow-wrap: anywhere; line-height: 1.45; }
        .status { color: GrayText; }
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
