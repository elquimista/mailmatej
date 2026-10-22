import Foundation
import Markdown

/// Composed Markdown as the HTML part of a message, as MailMate sends Markdown: CommonMark with GitHub's
/// extensions (tables, strikethrough, task lists), a line break wherever the text has one (mail is
/// written line by line, not in reflowed paragraphs), quotes as gray barred blockquotes, HTML typed in the
/// text shown as text, and inline styles only (mail clients drop style sheets). The text part stays the
/// Markdown as typed.
public enum MarkdownMail {
    public static func html(_ markdown: String) -> String {
        var writer = Writer()
        writer.visit(Document(parsing: markdown))
        return """
            <!DOCTYPE html>
            <html><head><meta charset="utf-8"></head>
            <body><div style="font-family: -apple-system, Helvetica, Arial, sans-serif; font-size: 14px; line-height: 1.4;">
            \(writer.result)</div></body></html>
            """
    }

    /// The `cid:` references in the Markdown's images (the Content-IDs of embedded pictures).
    public static func imageContentIDs(_ markdown: String) -> Set<String> {
        var finder = ImageFinder()
        finder.visit(Document(parsing: markdown))
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

        mutating func visitParagraph(_ paragraph: Paragraph) {
            wrap("<p style=\"margin: 0 0 1em;\">", "</p>\n", paragraph)
        }

        mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
            wrap(
                "<blockquote style=\"margin: 0 0 1em; padding: 0 0 0 8px; border-left: 2px solid #A0A0A0; color: #808080;\">\n",
                "</blockquote>\n", blockQuote)
        }

        mutating func visitHeading(_ heading: Heading) {
            wrap("<h\(heading.level)>", "</h\(heading.level)>\n", heading)
        }

        mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
            result += "<pre style=\"margin: 0 0 1em; padding: 8px; background: rgba(127,127,127,0.12); border-radius: 4px;"
                + " font-family: Menlo, monospace; font-size: 12px; white-space: pre-wrap;\"><code>"
                + MarkdownMail.escape(codeBlock.code) + "</code></pre>\n"
        }

        mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
            result += "<hr style=\"border: 0; border-top: 1px solid #A0A0A0;\">\n"
        }

        // HTML typed in the text shows as typed: in mail, "<city>" or "<name here>" is text, not markup.
        mutating func visitHTMLBlock(_ html: HTMLBlock) {
            result += "<p style=\"margin: 0 0 1em;\">" + MarkdownMail.escape(html.rawHTML).replacingOccurrences(of: "\n", with: "<br>\n") + "</p>\n"
        }

        mutating func visitUnorderedList(_ list: UnorderedList) { wrap("<ul style=\"margin: 0 0 1em;\">\n", "</ul>\n", list) }

        mutating func visitOrderedList(_ list: OrderedList) {
            let start = list.startIndex != 1 ? " start=\"\(list.startIndex)\"" : ""
            wrap("<ol\(start) style=\"margin: 0 0 1em;\">\n", "</ol>\n", list)
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
            wrap("<table style=\"border-collapse: collapse; margin: 0 0 1em;\">\n", "</table>\n", table)
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
            result += "<code style=\"font-family: Menlo, monospace; font-size: 12px; background: rgba(127,127,127,0.12);"
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
