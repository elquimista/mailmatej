import Foundation

/// Several messages shown together, as MailMate shows a selection of them: one card per message down a
/// single page, each its header fields, a rule, its attachments and remote-content bar, and its content
/// in a frame of its own (its page from `MessagePage`, so an email's CSS stays inside its card). Measured
/// on MailMate's (dark, at 1.89 px a point): cards 8 pt from the pane's edges and 8 pt apart, a 1 pt
/// border (4 pt at the left); in a card the fields 8 pt in, the label column at least 4.5 em wide, the
/// rule 0.5 em under them and 8 pt from the sides, the content 8 pt under the rule. Around the cards,
/// the list's background (the pane's, see MessageViewController).
public enum MessageStackPage {
    /// The scheme the page and its frames are served by: `mmj-stack://stack/` the page,
    /// `mmj-stack://stack/m/<id>/<generation>` a message's content.
    public static let scheme = "mmj-stack"

    /// MailMate's limit (its MmMaximumMessagesDisplayed, 100 by default): with more selected, the message
    /// view stays blank.
    public static let maximum = 100

    public static var pageURL: URL { URL(string: "\(scheme)://stack/")! }

    /// A message's content: a new generation for each change (its remote content loaded), so the frame
    /// loads it anew.
    public static func frameURL(id: Int64, generation: Int) -> String { "\(scheme)://stack/m/\(id)/\(generation)" }

    /// The message and generation a frame's URL asks for.
    public static func frame(of url: URL) -> (id: Int64, generation: Int)? {
        let parts = url.path.split(separator: "/")
        guard url.scheme == scheme, parts.count == 3, parts[0] == "m", let id = Int64(parts[1]), let generation = Int(parts[2])
        else { return nil }
        return (id, generation)
    }

    public struct Card: Sendable {
        public var id: Int64
        /// The header fields, the empty ones left out.
        public var fields: [Field]

        public init(id: Int64, fields: [Field]) {
            self.id = id
            self.fields = fields.filter { !$0.value.isEmpty }
        }
    }

    public struct Field: Sendable {
        public var label: String
        public var value: String
        /// Whether a search looks at it, so marks what it finds there (not the Date; Find does).
        public var searched: Bool

        public init(_ label: String, _ value: String, searched: Bool = true) {
            self.label = label
            self.value = value
            self.searched = searched
        }
    }

    public struct Attachment: Sendable {
        public var name: String
        public var size: String
        /// The file type's icon, as a data: URL.
        public var icon: String?

        public init(name: String, size: String, icon: String?) {
            self.name = name
            self.size = size
            self.icon = icon
        }
    }

    /// The page: the cards in order, each with its content's frame (filled in when the message is ready).
    /// `detailsOpen`: the remote-content bars show their details, as the single message's do.
    public static func html(cards: [Card], detailsOpen: Bool) -> String {
        let policy = "default-src 'none'; style-src 'unsafe-inline'; img-src data:; frame-src \(scheme):"
        return """
            <!doctype html><html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="\(policy)">
            <meta name="color-scheme" content="light dark">
            <style>\(MessagePage.pageCSS)\(css)</style>
            </head><body\(detailsOpen ? #" class="mmj-open""# : "")>\(cards.map(card).joined())<mmj-end></mmj-end></body></html>
            """
    }

    static func card(_ card: Card) -> String {
        let rows = card.fields.map { field in
            "<tr\(field.searched ? "" : " data-nosearch")><td>\(MessagePage.escape(field.label))</td><td>\(MessagePage.escape(field.value))</td></tr>"
        }
        return "<mmj-card id=\"c\(card.id)\"><table>\(rows.joined())</table><hr><mmj-extras></mmj-extras>"
            + "<iframe id=\"f\(card.id)\" src=\"\(frameURL(id: card.id, generation: 0))\"></iframe></mmj-card>"
    }

    /// What goes between a card's rule and its content once the message is ready: its attachments, then
    /// its remote-content bar (with Download All, `downloadAll` resources, when other cards have remote
    /// content to load too).
    public static func extras(attachments: [Attachment], bar: MessagePage.Bar?, downloadAll: Int) -> String {
        var html = ""
        if !attachments.isEmpty {
            html += "<mmj-files>" + attachments.enumerated().map { index, file in
                let icon = file.icon.map { "<img src=\"\(MessagePage.escape($0))\">" } ?? "<img>"
                return "<mmj-file data-i=\"\(index)\">\(icon)<span>\(MessagePage.escape(file.name))</span>"
                    + "<span>\(MessagePage.escape(file.size))</span></mmj-file>"
            }.joined() + "</mmj-files>"
        }
        guard let bar else { return html }
        var buttons = bar.actions.map { (title: $0.title, action: $0.action.rawValue) }
        if !bar.loaded, downloadAll > bar.remote - bar.strict { buttons.insert(("Download All (\(downloadAll))", "loadAll"), at: 0) }
        let level = switch bar.level {
        case .yellow: "yellow"
        case .orange: "orange"
        case .red: "red"
        }
        let bare = buttons.isEmpty ? " bare" : ""
        html += "<mmj-bar class=\"\(level)\(bare)\"><mmj-tri></mmj-tri><span>\(MessagePage.escape(bar.text))</span>"
        for button in buttons {
            html += "<mmj-button data-act=\"\(button.action)\">\(MessagePage.escape(button.title))</mmj-button>"
        }
        html += "</mmj-bar><mmj-details>"
        for row in bar.details {
            let lines: String = row.lines.map(MessagePage.escape).joined(separator: "<br>")
            html += "<mmj-row><span>\(MessagePage.escape(row.label))</span><span>\(lines)</span></mmj-row>"
        }
        return html + "</mmj-details>"
    }

    /// The cards as measured on MailMate's; the fields as its own headers.css (a table, cells 0.5 em
    /// apart, labels right-aligned in at least 4.5 em); the rule as its gradient; the bar and attachments
    /// as the single message's native ones (see MessageHeaderView).
    static let css = """

        html, body { margin: 0; padding: 0; }
        body { padding: 8px 8px 0; font: 13px -apple-system, sans-serif; background: transparent;
          --card: #fff; --border: #8e8e92; --label: gray; --value: #000; --ruler-start: #ccc; --ruler-middle: #333;
          --files: rgba(0, 0, 0, 0.05); --file-even: rgba(0, 0, 0, 0.04); --file-text: rgb(29, 29, 31);
          -webkit-user-select: text; cursor: default; }
        @media (prefers-color-scheme: dark) {
          body { --card: #303234; --border: #a0a0a4; --label: gray; --value: #fff; --ruler-start: #333; --ruler-middle: #ccc;
            --files: rgb(32, 35, 38); --file-even: rgb(42, 46, 47); --file-text: rgb(222, 222, 222); }
        }
        mmj-card { display: block; margin-bottom: 8px; background: var(--card); border: 1px solid var(--border);
          border-left-width: 4px; overflow: hidden; }
        mmj-card > table { border-spacing: 0.5em 0; margin: 8px 8px 0; }
        mmj-card > table td { padding: 1px; vertical-align: top; color: var(--value); overflow-wrap: anywhere; }
        mmj-card > table td:first-child { text-align: right; min-width: 4.5em; white-space: nowrap; color: var(--label); }
        mmj-card > hr { border: 0; height: 1px; margin: 0.5em 8px 8px; background: var(--ruler-middle);
          background-image: linear-gradient(to right, var(--ruler-start), var(--ruler-middle), var(--ruler-start)); }
        mmj-card > iframe { display: block; width: 100%; height: 0; border: 0; }
        mmj-extras { display: block; }
        mmj-files { display: block; padding: 5px 4px; background: var(--files); }
        mmj-file { display: flex; align-items: center; height: 23px; border-radius: 4px; color: var(--file-text); }
        mmj-file:nth-child(even) { background: var(--file-even); }
        mmj-file > img { width: 20px; height: 20px; margin: 0 5px 0 11px; flex: none; }
        mmj-file > span:first-of-type { flex: 1; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        mmj-file > span:last-of-type { margin: 0 14px 0 12px; flex: none; }
        mmj-bar { display: flex; align-items: center; position: relative; height: 30px; padding: 0 7px 0 19px; color: #000; }
        mmj-bar.bare { height: 28px; }
        mmj-bar.yellow { background: rgb(255, 214, 10); }
        mmj-bar.orange { background: rgb(255, 159, 10); }
        mmj-bar.red { background: rgb(255, 69, 58); }
        mmj-bar > span { flex: 1; padding-left: 3px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        mmj-tri { position: absolute; left: 6.33px; top: 11.9px; width: 0; height: 0; border-style: solid; border-color: transparent;
          border-width: 2.6px 0 2.6px 5.37px; border-left-color: #000; }
        body.mmj-open mmj-tri { left: 7.25px; top: 11.92px; border-width: 5.36px 2.68px 0; border-color: transparent; border-top-color: #000; }
        mmj-button { display: block; flex: none; height: 18px; line-height: 18px; margin-left: 10px; padding: 0 7px;
          border: 1px solid #000; border-radius: 4px; }
        mmj-button:active { background: rgba(0, 0, 0, 0.15); }
        mmj-details { display: none; padding: 5px 0 4px; background: rgb(238, 238, 238); color: #000; line-height: 16px; }
        body.mmj-open mmj-details { display: block; }
        mmj-row { display: flex; }
        mmj-row + mmj-row { margin-top: 10px; }
        mmj-row > span:first-child { flex: none; width: 196px; padding-left: 4px; }
        mmj-row > span:last-child { flex: 1; padding-right: 16px; overflow-wrap: anywhere; -webkit-user-select: text; }
        """
}
