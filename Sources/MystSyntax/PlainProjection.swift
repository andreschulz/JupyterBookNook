import Foundation

/// MyST source seen as the text a reader sees: emphasis, code and math markers, role names, link
/// targets and block markers left out, runs of white space as one space. Each character of
/// `text` remembers where it came from, so text selected in the rendered page can be found in
/// the source again (selection highlighting between editor and preview).
public struct PlainProjection: Equatable, Sendable {
    /// The plain text, lowercased, with single spaces.
    public let text: String
    /// For each UTF-16 unit of `text`, its offset in the source.
    public let sourceOffsets: [Int]

    public init(_ source: String) {
        let units = Array(source.utf16)
        var plain: [UInt16] = []
        var offsets: [Int] = []
        var i = 0
        var atLineStart = true
        let space: UInt16 = 32

        func append(_ unit: UInt16, at offset: Int) {
            let isSpace = unit == space || unit == 10 || unit == 9 || unit == 13
            if isSpace {
                guard let last = plain.last, last != space else { return }
                plain.append(space)
            } else {
                plain.append(unit)
            }
            offsets.append(offset)
        }
        func isWordUnit(_ unit: UInt16) -> Bool {
            guard let scalar = Unicode.Scalar(unit) else { return true } // surrogates: letters
            return CharacterSet.alphanumerics.contains(scalar)
        }

        while i < units.count {
            let unit = units[i]
            if atLineStart {
                // Block markers: headings, quotes, list bullets and numbers, then their space.
                var j = i
                while j < units.count, units[j] == space { j += 1 }
                var k = j
                if k < units.count, units[k] == 35 /* # */ { while k < units.count, units[k] == 35 { k += 1 } }
                else if k < units.count, units[k] == 62 /* > */ { k += 1 }
                else if k + 1 < units.count, [45, 42, 43].contains(units[k]) /* - * + */, units[k + 1] == space { k += 1 }
                else {
                    var digits = k
                    while digits < units.count, (48...57).contains(units[digits]) { digits += 1 }
                    if digits > k, digits < units.count, units[digits] == 46 || units[digits] == 41 /* . ) */ { k = digits + 1 }
                }
                if k > j, k < units.count, units[k] == space || units[k] == 10 {
                    i = k
                    atLineStart = false
                    continue
                }
                atLineStart = false
            }
            switch unit {
            case 10:
                append(unit, at: i)
                atLineStart = true
                i += 1
            case 42, 95, 96, 36, 126: // * _ ` $ ~
                // `_` inside a word (snake_case) is text.
                if unit == 95, i > 0, i + 1 < units.count, isWordUnit(units[i - 1]), isWordUnit(units[i + 1]) {
                    append(unit, at: i)
                }
                i += 1
            case 123: // {role}`…` → the content; other braces stay
                var j = i + 1
                while j < units.count, units[j] != 125, units[j] != 10, j - i < 40 { j += 1 }
                if j + 1 < units.count, units[j] == 125, units[j + 1] == 96 {
                    i = j + 1 // the backtick is skipped next
                } else {
                    append(unit, at: i)
                    i += 1
                }
            case 91: // [text](target) → text
                i += 1
            case 93: // ](target) or ][label]
                if i + 1 < units.count, units[i + 1] == 40 || units[i + 1] == 91 {
                    let close: UInt16 = units[i + 1] == 40 ? 41 : 93
                    var j = i + 2
                    while j < units.count, units[j] != close, units[j] != 10 { j += 1 }
                    i = min(units.count, j + 1)
                } else {
                    i += 1
                }
            default:
                append(unit, at: i)
                i += 1
            }
        }
        // Trailing space.
        if plain.last == space {
            plain.removeLast()
            offsets.removeLast()
        }
        text = String(decoding: plain, as: UTF16.self).lowercased()
        // Lowercasing can change the length (rare: e.g. "İ"); keep the map usable.
        let length = text.utf16.count
        if length != offsets.count {
            offsets = Array(offsets.prefix(length)) + Array(repeating: offsets.last ?? 0, count: max(0, length - offsets.count))
        }
        sourceOffsets = offsets
    }

    /// `text` as a projection would show it: lowercased, single spaces, trimmed.
    public static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The source range of the first occurrence of `rendered` (text as the page shows it), or nil.
    public func sourceRange(of rendered: String) -> NSRange? {
        let needle = Self.normalized(rendered)
        guard !needle.isEmpty, let found = (text as NSString).range(of: needle).nonEmpty else { return nil }
        let start = sourceOffsets[found.location]
        let end = sourceOffsets[NSMaxRange(found) - 1] + 1
        return NSRange(location: start, length: end - start)
    }
}

extension PlainProjection {
    /// Where text selected in the rendered page is in `source`, given the lines (1-based) the page
    /// says it spans: the occurrence nearest to those lines within a few lines around them, or the
    /// lines themselves when the text is not found there.
    public static func sourceRange(of rendered: String, lines: ClosedRange<Int>, in source: String, slack: Int = 3) -> NSRange? {
        let ns = source as NSString
        var starts = [0]
        for (index, unit) in source.utf16.enumerated() where unit == 10 { starts.append(index + 1) }
        func span(_ first: Int, _ last: Int) -> NSRange {
            let a = min(starts.count - 1, max(0, first - 1))
            let b = min(starts.count - 1, max(a, last - 1))
            var end = b + 1 < starts.count ? starts[b + 1] : ns.length
            if end > starts[a], ns.character(at: end - 1) == 10 { end -= 1 }
            return NSRange(location: starts[a], length: max(0, end - starts[a]))
        }
        let window = span(lines.lowerBound - slack, lines.upperBound + slack)
        let wanted = span(lines.lowerBound, lines.upperBound)
        let projection = PlainProjection(ns.substring(with: window))
        let needle = normalized(rendered)
        // 0 inside the lines the page named, else how far outside them.
        func distance(_ range: NSRange) -> Int {
            if range.location >= wanted.location, range.location <= NSMaxRange(wanted) { return 0 }
            return range.location < wanted.location ? wanted.location - range.location : range.location - NSMaxRange(wanted)
        }
        if !needle.isEmpty {
            let haystack = projection.text as NSString
            var best: NSRange?
            var search = NSRange(location: 0, length: haystack.length)
            while let found = haystack.range(of: needle, range: search).nonEmpty {
                let start = window.location + projection.sourceOffsets[found.location]
                let end = window.location + projection.sourceOffsets[NSMaxRange(found) - 1] + 1
                let candidate = NSRange(location: start, length: end - start)
                if best.map({ distance($0) > distance(candidate) }) ?? true { best = candidate }
                search = NSRange(location: NSMaxRange(found), length: haystack.length - NSMaxRange(found))
            }
            if let best { return best }
        }
        return wanted.length > 0 ? wanted : nil
    }
}

private extension NSRange {
    var nonEmpty: NSRange? { location == NSNotFound || length == 0 ? nil : self }
}
