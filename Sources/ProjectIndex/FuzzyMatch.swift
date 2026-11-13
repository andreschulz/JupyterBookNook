import Foundation

/// Subsequence matching for Quick Open and the command palette: every character of the query must
/// appear in order. Matches at word starts and runs of consecutive characters score higher, so
/// "gd" finds "Gradient Descent" before "Good examples".
public enum FuzzyMatch {
    /// A score (higher is better), or nil when `query` does not match. An empty query matches
    /// everything with score 0.
    public static func score(_ query: String, in candidate: String) -> Int? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        let original = Array(candidate)
        let haystack = Array(candidate.lowercased())
        guard haystack.count == original.count else { return plainScore(needle, in: haystack) }
        var score = 0
        var position = 0
        var previousMatch = -2
        for character in needle {
            let index: Int
            if previousMatch == position - 1, position < haystack.count, haystack[position] == character {
                index = position // continue a run
            } else if let start = (position..<haystack.count).first(where: { haystack[$0] == character && isWordStart(original, $0) }) {
                index = start // "gd" lands on Gradient Descent's D, not on "graDient"
            } else if let first = (position..<haystack.count).first(where: { haystack[$0] == character }) {
                index = first
            } else {
                // Jumping to word starts can skip characters needed later; fall back to a plain match.
                return plainScore(needle, in: haystack)
            }
            score += 1
            if isWordStart(original, index) { score += 8 }
            if index == previousMatch + 1 { score += 5 }
            if index == 0 { score += 6 }
            score -= min(index - position, 6)
            previousMatch = index
            position = index + 1
        }
        // Shorter candidates win among equal matches.
        return score * 4 - min(haystack.count, 40) / 4
    }

    private static func plainScore(_ needle: [Character], in haystack: [Character]) -> Int? {
        var position = 0
        for character in needle {
            guard let index = (position..<haystack.count).first(where: { haystack[$0] == character }) else { return nil }
            position = index + 1
        }
        return 1
    }

    private static func isWordStart(_ text: [Character], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = text[index - 1]
        let current = text[index]
        if !previous.isLetter && !previous.isNumber { return true }
        return current.isUppercase && previous.isLowercase
    }

    /// The best score over several fields of an item (title, path, …), the first weighted highest.
    public static func score(_ query: String, in fields: [String]) -> Int? {
        fields.enumerated().compactMap { offset, field in score(query, in: field).map { $0 - offset * 3 } }.max()
    }
}
