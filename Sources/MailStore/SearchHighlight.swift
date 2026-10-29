import Foundation

/// What a search marks in the message shown, as MailMate does: a word of it, or a "quoted phrase"
/// whole, found ignoring case and accents.
public struct SearchHighlight: Hashable, Sendable {
    public var text: String
    /// Only where a word starts, as the search index matches its words ("morg" marks "Morgan" but not
    /// "Stormorg"); otherwise anywhere (a Subject contains rule).
    public var wordStart: Bool
    /// The text it came from (the search field's, or one Contains row's): only marks of the same text
    /// side by side join into one.
    public var group: Int

    public init(_ text: String, wordStart: Bool = true, group: Int = 0) {
        self.text = text
        self.wordStart = wordStart
        self.group = group
    }

    /// The words of a search's text, a "quoted phrase" kept whole (an unclosed quote runs to the end).
    public static func terms(_ text: String, wordStart: Bool = true, group: Int = 0) -> [SearchHighlight] {
        var terms: [String] = []
        for (index, part) in text.split(separator: "\"", omittingEmptySubsequences: false).enumerated() {
            if index % 2 == 1 {
                terms.append(part.split(whereSeparator: \.isWhitespace).joined(separator: " "))  // inside quotes
            } else {
                terms += part.split(whereSeparator: \.isWhitespace).map(String.init)
            }
        }
        var seen = Set<String>()
        return terms.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .map { SearchHighlight($0, wordStart: wordStart, group: group) }
    }

    /// Where any of `highlights` shows in `string`, in order: overlapping ones, and ones of the same text
    /// only spaces part (the words of "J.P. Morgan Workplace" side by side), merged into one. A merged
    /// mark keeps every text found in it, so two rows with the same words still mark them as one.
    /// Without `joiningSpaced` (Find, which counts each), only overlapping ones merge.
    public static func ranges(of highlights: [SearchHighlight], in string: String, joiningSpaced: Bool = true) -> [NSRange] {
        let text = string as NSString
        var found: [(range: NSRange, group: Int)] = []
        for highlight in highlights {
            var from = 0
            while from < text.length {
                let range = text.range(
                    of: highlight.text, options: [.caseInsensitive, .diacriticInsensitive],
                    range: NSRange(location: from, length: text.length - from))
                guard range.location != NSNotFound, range.length > 0 else { break }
                if !highlight.wordStart || range.location == 0 || !isWordCharacter(text.character(at: range.location - 1)) {
                    found.append((range, highlight.group))
                }
                from = range.location + range.length
            }
        }
        func onlySpaces(_ from: Int, _ to: Int) -> Bool {
            from >= to || text.substring(with: NSRange(location: from, length: to - from)).allSatisfy(\.isWhitespace)
        }
        var merged: [(range: NSRange, groups: Set<Int>)] = []
        for (range, group) in found.sorted(by: { $0.range.location < $1.range.location }) {
            if let last = merged.last, range.location <= NSMaxRange(last.range)
                || (joiningSpaced && last.groups.contains(group) && onlySpaces(NSMaxRange(last.range), range.location))
            {
                merged[merged.count - 1] = (NSUnionRange(last.range, range), last.groups.union([group]))
            } else {
                merged.append((range, [group]))
            }
        }
        return merged.map(\.range)
    }

    private static func isWordCharacter(_ unit: unichar) -> Bool {
        Unicode.Scalar(unit).map { CharacterSet.alphanumerics.contains($0) } ?? false
    }
}

extension SmartCondition {
    /// What the search marks in the message shown: the text its enabled Contains rows look for (the
    /// search index's fields by word, Subject and addresses anywhere), each row's its own group.
    public var highlights: [SearchHighlight] {
        var rows = 0
        return highlights(counting: &rows)
    }

    private func highlights(counting rows: inout Int) -> [SearchHighlight] {
        switch self {
        case .compound(_, let children, let enabled):
            guard enabled else { return [] }
            return children.flatMap { $0.highlights(counting: &rows) }
        case .rule(let field, .contains, let value, let enabled, _) where enabled:
            rows += 1
            if field.isFullText { return SearchHighlight.terms(value, group: rows) }
            let shown = field == .subject || field.address != nil
            return shown && !value.isEmpty ? [SearchHighlight(value, wordStart: false, group: rows)] : []
        case .rule:
            return []
        }
    }
}
