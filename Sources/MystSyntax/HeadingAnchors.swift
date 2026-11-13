import Foundation

/// A heading in the rendered preview: its HTML id, text and level.
public struct PreviewHeading: Equatable, Sendable {
    public var id: String
    public var text: String
    public var level: Int

    public init(id: String, text: String, level: Int) {
        self.id = id
        self.text = text
        self.level = level
    }
}

/// Pairs the headings of a page's source with the headings MyST renders, for scroll sync.
public enum HeadingAnchors {
    /// The id MyST gives each heading: its `(label)=` target, or one derived from its text,
    /// with `-1`, `-2`, … for repeats.
    public static func anchors(for headings: [MystHeading]) -> [String] {
        var used: [String: Int] = [:]
        return headings.map { heading in
            if let label = heading.label { return label }
            let base = autoID(for: plainText(heading.title))
            let count = used[base, default: 0]
            used[base] = count + 1
            return count == 0 ? base : "\(base)-\(count)"
        }
    }

    /// Roughly the text MyST renders for a heading: roles are dropped (cross-references are
    /// resolved later and do not count), inline code, links and emphasis keep their text,
    /// math keeps its source.
    public static func plainText(_ title: String) -> String {
        var text = title
        let replacements: [(String, String)] = [
            (#"\{[A-Za-z][\w:.-]*\}(`+).*?\1"#, ""),         // {ref}`label`
            (#"!?\[([^\]]*)\]\([^)]*\)"#, "$1"),             // [text](target)
            (#"(`+)(.*?)\1"#, "$2"),                        // `code`
            (#"\$([^$]*)\$"#, "$1"),                        // $math$
            (#"(\*\*|__)(.+?)\1"#, "$2"),                   // **strong**
            (#"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#, "$1"),
            (#"(?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)"#, "$1"),
        ]
        for (pattern, template) in replacements {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// MyST's id for a heading text: lowercase, apostrophes removed, every other run of
    /// characters outside a–z and 0–9 replaced by "-"; prefixed "id-" unless it starts with a letter.
    /// Matches mystmd 1.11, e.g. "Über Größe" → "id-ber-gr-e", "Numbers 1.2 and C++" → "numbers-1-2-and-c".
    public static func autoID(for text: String) -> String {
        var slug = ""
        for scalar in text.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                slug.unicodeScalars.append(scalar)
            } else if scalar == "'" || scalar == "\u{2019}" {
                continue
            } else if !slug.isEmpty && !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        let startsWithLetter = text.unicodeScalars.first.map { ("a"..."z").contains($0) || ("A"..."Z").contains($0) } ?? false
        return startsWithLetter ? slug : "id-" + slug
    }

    /// For each source heading, the index of its preview heading, or nil.
    /// Pairs by id first; headings left over are paired by text, then by position between pairs.
    public static func align(_ headings: [MystHeading], with preview: [PreviewHeading]) -> [Int?] {
        let anchors = anchors(for: headings)
        var result = [Int?](repeating: nil, count: headings.count)
        var taken = Set<Int>()
        var byID: [String: Int] = [:]
        for (index, heading) in preview.enumerated() where byID[heading.id] == nil { byID[heading.id] = index }
        for (index, anchor) in anchors.enumerated() {
            if let match = byID[anchor], !taken.contains(match) {
                result[index] = match
                taken.insert(match)
            }
        }
        // Between two pairs, try the leftovers by text, then by order.
        func normalized(_ text: String) -> String {
            String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
        }
        var index = 0
        while index < headings.count {
            guard result[index] == nil else { index += 1; continue }
            let start = index
            while index < headings.count, result[index] == nil { index += 1 }
            let lower = (start > 0 ? result[start - 1] : nil).map { $0 + 1 } ?? 0
            let upper = index < headings.count ? result[index] ?? preview.count : preview.count
            guard lower < upper else { continue }
            var free = Array(lower..<upper).filter { !taken.contains($0) }
            for source in start..<index {
                let wanted = normalized(plainText(headings[source].title))
                if let match = free.first(where: { normalized(preview[$0].text) == wanted }) {
                    result[source] = match
                    taken.insert(match)
                    free.removeAll { $0 == match }
                }
            }
            let unpaired = (start..<index).filter { result[$0] == nil }
            if unpaired.count == free.count {
                for (source, match) in zip(unpaired, free) {
                    result[source] = match
                    taken.insert(match)
                }
            }
        }
        return result
    }

    /// The source heading for a preview heading: the last source heading paired at or before it.
    public static func sourceIndex(forPreview previewIndex: Int, alignment: [Int?]) -> Int? {
        alignment.lastIndex { $0.map { $0 <= previewIndex } ?? false }
    }

    /// The preview heading to show for a source heading: its pair, or the closest paired one before it.
    public static func previewIndex(forSource sourceIndex: Int, alignment: [Int?]) -> Int? {
        guard alignment.indices.contains(sourceIndex) else { return nil }
        return alignment[...sourceIndex].reversed().lazy.compactMap { $0 }.first
    }
}
