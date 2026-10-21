import Foundation

/// Matches typed letters in order, not necessarily next to each other, as MailMate's mailbox picker does:
/// "postin" finds "postmaster@x.com Inbox". Lower scores are better matches: letters that run together
/// and start words cost least.
public enum FuzzyMatch {
    /// The best score of `query` (its space-separated words each matched on their own) in any of
    /// `texts`, or nil if some word matches none of them.
    public static func score(_ query: String, in texts: [String]) -> Int? {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return 0 }
        let lowered = texts.map { $0.lowercased() }
        var total = 0
        for word in words {
            guard let best = lowered.compactMap({ score(word, in: $0) }).min() else { return nil }
            total += best
        }
        return total
    }

    /// The cheapest way to find `word`'s letters in order in `text`: 0 per letter that starts a word or
    /// follows the previous one, 1 for a letter inside a word, 3 for each jump over skipped letters.
    static func score(_ word: String, in text: String) -> Int? {
        let w = Array(word), t = Array(text)
        guard !w.isEmpty, w.count <= t.count else { return w.isEmpty ? 0 : nil }
        let startsWord = t.indices.map { $0 == 0 || !(t[$0 - 1].isLetter || t[$0 - 1].isNumber) }
        let unreachable = Int.max / 4
        // best[j]: cheapest cost with the current letter matched at text position j.
        var best = [Int](repeating: unreachable, count: t.count)
        for j in t.indices where t[j] == w[0] { best[j] = startsWord[j] ? 0 : 1 }
        for i in 1..<w.count {
            var next = [Int](repeating: unreachable, count: t.count)
            var cheapestBefore = unreachable  // min over k < j - 1 of best[k] (a jump)
            for j in t.indices {
                if j >= 2 { cheapestBefore = min(cheapestBefore, best[j - 2]) }
                guard t[j] == w[i] else { continue }
                let adjacent = j >= 1 ? best[j - 1] : unreachable
                let jump = cheapestBefore == unreachable ? unreachable : cheapestBefore + 3 + (startsWord[j] ? 0 : 1)
                next[j] = min(adjacent, jump)
            }
            best = next
        }
        let result = best.min() ?? unreachable
        return result >= unreachable ? nil : result
    }
}
