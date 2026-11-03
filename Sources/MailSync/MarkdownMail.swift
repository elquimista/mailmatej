import Foundation
import Markdown

/// Composed Markdown as the HTML part of a message, as MailMate sends Markdown (matched to the HTML
/// MailMate 3 generates): CommonMark with GitHub's extensions (tables, strikethrough, task lists), plain
/// punctuation (no curly quotes or dashes), a line break wherever the text has one (mail is written line
/// by line), MailMate's quote style, `sans-serif` with the reader's own size and spacing, HTML typed in
/// the text shown as text, and inline styles only (mail clients drop style sheets).
public enum MarkdownMail {
    public static func html(_ markdown: String) -> String {
        var writer = Writer()
        writer.visit(Document(parsing: markdown, options: [.disableSmartOpts]))
        return """
            <!DOCTYPE html>
            <html>
            <head>
            <meta http-equiv="Content-Type" content="text/xhtml; charset=utf-8">
            </head>
            <body style="font-family: sans-serif;">
            <div class="markdown" style="white-space: normal;">
            \(writer.result)
            </div></body>

            </html>

            """
    }

    /// The HTML of Markdown whose signature (the text in `signature`) has an HTML variant: that, as typed,
    /// in its place.
    public static func html(_ markdown: String, signature: NSRange, signatureHTML: String) -> String {
        let token = "MMJSIGNATURE" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let page = html((markdown as NSString).replacingCharacters(in: signature, with: "\n\(token)\n\n"))
        return page.replacingOccurrences(of: "<p dir=\"auto\">\(token)</p>", with: signatureHTML)
    }

    /// A plain-text message as HTML, for a signature with an HTML variant (MailMate then sends HTML too):
    /// the text with its lines kept, and the signature's HTML in its place.
    public static func plainHTML(_ text: String, signature: NSRange, signatureHTML: String) -> String {
        let source = text as NSString
        func lines(_ part: String) -> String { escape(part).replacingOccurrences(of: "\n", with: "<br>\n") }
        let before = lines(source.substring(to: signature.location))
        let after = lines(source.substring(from: NSMaxRange(signature)))
        return """
            <!DOCTYPE html>
            <html>
            <head>
            <meta http-equiv="Content-Type" content="text/xhtml; charset=utf-8">
            </head>
            <body style="font-family: sans-serif;">
            \(before)\(signatureHTML)
            \(after)</body>

            </html>

            """
    }

    /// The text part of a Markdown message, as MailMate writes it: the Markdown as typed, but an embedded
    /// picture (`![](cid:… "name")`, meaningless outside the HTML) as `[ "name" ]`.
    public static func plainText(_ markdown: String) -> String {
        let text = markdown as NSString
        var out = ""
        var last = 0
        for match in embeddedPictures.matches(in: markdown, range: NSRange(location: 0, length: text.length)) {
            func group(_ i: Int) -> String? {
                let range = match.range(at: i)
                return range.location == NSNotFound ? nil : text.substring(with: range)
            }
            let name = [group(2), group(1)].compactMap { $0 }.first { !$0.isEmpty } ?? "Image"
            out += text.substring(with: NSRange(location: last, length: match.range.location - last)) + "[ \"\(name)\" ]"
            last = match.range.location + match.range.length
        }
        return out + text.substring(from: last)
    }

    /// `![alt](cid:… "title")`: alt in group 1, title in group 2.
    private static let embeddedPictures = try! NSRegularExpression(
        pattern: #"!\[([^\]]*)\]\(<?cid:[^\s)>]+>?(?:\s+"([^"]*)")?\)"#)

    /// The `cid:` references in the Markdown's images (the Content-IDs of embedded pictures).
    public static func imageContentIDs(_ markdown: String) -> Set<String> {
        var finder = ImageFinder()
        finder.visit(Document(parsing: markdown, options: [.disableSmartOpts]))
        return finder.ids
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for c in text {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }

    private struct ImageFinder: MarkupWalker {
        var ids: Set<String> = []
        mutating func visitImage(_ image: Image) {
            if let source = image.source, source.lowercased().hasPrefix("cid:") { ids.insert(String(source.dropFirst(4))) }
        }
    }

    private struct Writer: MarkupWalker {
        var result = ""
        private var inTableHead = false
        private var alignments: [Table.ColumnAlignment?] = []
        private var column = 0

        private mutating func wrap(_ open: String, _ close: String, _ markup: Markup) {
            result += open
            descendInto(markup)
            result += close
        }

        // Blocks

        mutating func visitParagraph(_ paragraph: Paragraph) { wrap("<p dir=\"auto\">", "</p>\n", paragraph) }

        mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
            wrap(
                "<blockquote style=\"margin: 0 0 5px; padding-left: 5px; border-left: 2px solid #777777; color: #777777;\">\n",
                "</blockquote>\n", blockQuote)
        }

        mutating func visitHeading(_ heading: Heading) {
            wrap("<h\(heading.level)>", "</h\(heading.level)>\n", heading)
        }

        mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
            result += "<pre style=\"padding: 8px; background: rgba(127,127,127,0.12); border-radius: 4px;"
                + " font-family: Menlo, monospace; white-space: pre-wrap;\"><code>"
                + MarkdownMail.escape(codeBlock.code) + "</code></pre>\n"
        }

        mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
            result += "<hr>\n"
        }

        // HTML typed in the text shows as typed: in mail, "<city>" or "<name here>" is text, not markup.
        mutating func visitHTMLBlock(_ html: HTMLBlock) {
            result += "<p dir=\"auto\">" + MarkdownMail.escape(html.rawHTML).replacingOccurrences(of: "\n", with: "<br>\n") + "</p>\n"
        }

        mutating func visitUnorderedList(_ list: UnorderedList) { wrap("<ul>\n", "</ul>\n", list) }

        mutating func visitOrderedList(_ list: OrderedList) {
            let start = list.startIndex != 1 ? " start=\"\(list.startIndex)\"" : ""
            wrap("<ol\(start)>\n", "</ol>\n", list)
        }

        mutating func visitListItem(_ item: ListItem) {
            result += "<li>"
            if let checkbox = item.checkbox { result += checkbox == .checked ? "☑ " : "☐ " }
            // A tight list's items hold paragraphs too: no paragraph margins inside them.
            for child in item.children {
                if let paragraph = child as? Paragraph {
                    descendInto(paragraph)
                } else {
                    visit(child)
                }
            }
            result += "</li>\n"
        }

        mutating func visitTable(_ table: Table) {
            alignments = table.columnAlignments
            wrap("<table style=\"border-collapse: collapse;\">\n", "</table>\n", table)
        }

        mutating func visitTableHead(_ head: Table.Head) {
            inTableHead = true
            column = 0
            wrap("<thead><tr>\n", "</tr></thead>\n", head)
            inTableHead = false
        }

        mutating func visitTableBody(_ body: Table.Body) { wrap("<tbody>\n", "</tbody>\n", body) }

        mutating func visitTableRow(_ row: Table.Row) {
            column = 0
            wrap("<tr>\n", "</tr>\n", row)
        }

        mutating func visitTableCell(_ cell: Table.Cell) {
            let tag = inTableHead ? "th" : "td"
            var style = "border: 1px solid #A0A0A0; padding: 3px 6px;"
            if column < alignments.count, let alignment = alignments[column] {
                style += " text-align: \(alignment == .left ? "left" : alignment == .right ? "right" : "center");"
            }
            column += 1
            wrap("<\(tag) style=\"\(style)\">", "</\(tag)>\n", cell)
        }

        // Inline

        mutating func visitText(_ text: Text) { result += MarkdownMail.escape(text.string) }

        mutating func visitSoftBreak(_ softBreak: SoftBreak) { result += "<br>\n" }  // mail keeps its lines

        mutating func visitLineBreak(_ lineBreak: LineBreak) { result += "<br>\n" }

        mutating func visitEmphasis(_ emphasis: Emphasis) { wrap("<em>", "</em>", emphasis) }

        mutating func visitStrong(_ strong: Strong) { wrap("<strong>", "</strong>", strong) }

        mutating func visitStrikethrough(_ strikethrough: Strikethrough) { wrap("<del>", "</del>", strikethrough) }

        mutating func visitInlineCode(_ code: InlineCode) {
            result += "<code style=\"font-family: Menlo, monospace; background: rgba(127,127,127,0.12);"
                + " padding: 0 2px; border-radius: 3px;\">" + MarkdownMail.escape(code.code) + "</code>"
        }

        mutating func visitInlineHTML(_ html: InlineHTML) { result += MarkdownMail.escape(html.rawHTML) }

        mutating func visitLink(_ link: Link) {
            let href = link.destination.map { " href=\"\(MarkdownMail.escape($0))\"" } ?? ""
            wrap("<a\(href)>", "</a>", link)
        }

        mutating func visitImage(_ image: Image) {
            var tag = "<img"
            if let source = image.source, !source.isEmpty { tag += " src=\"\(MarkdownMail.escape(source))\"" }
            tag += " alt=\"\(MarkdownMail.escape(image.plainText))\""
            if let title = image.title, !title.isEmpty { tag += " title=\"\(MarkdownMail.escape(title))\"" }
            result += tag + " style=\"max-width: 100%;\">"
        }
    }
}
