import Foundation

/// A heading in a page, for the outline and the breadcrumb.
public struct MystHeading: Equatable, Sendable {
    public var level: Int
    public var title: String
    /// The heading's line.
    public var range: NSRange
    /// The `(label)=` target directly above the heading, if any.
    public var label: String?
}

public enum MystOutline {
    public static func headings(in text: String, tokens: [MystToken]? = nil) -> [MystHeading] {
        let ns = text as NSString
        let tokens = tokens ?? MystTokenizer.tokens(in: text)
        var result: [MystHeading] = []
        var pendingLabel: (label: String, end: Int)?
        for token in tokens {
            switch token.kind {
            case .target:
                let raw = ns.substring(with: token.range)
                pendingLabel = (String(raw.dropFirst().prefix(while: { $0 != ")" })), token.range.location + token.range.length)
            case .heading(let level):
                var title = ns.substring(with: token.range).trimmingCharacters(in: .whitespaces)
                title = String(title.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                // A closing sequence of #s is not part of the title.
                if let closing = title.range(of: #"\s+#+$"#, options: .regularExpression) { title.removeSubrange(closing) }
                if title == String(repeating: "#", count: title.count) { title = "" }
                // The label applies only when nothing but blank lines separates it from the heading.
                var label: String?
                if let pending = pendingLabel {
                    let between = ns.substring(with: NSRange(location: pending.end, length: token.range.location - pending.end))
                    if between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { label = pending.label }
                }
                result.append(MystHeading(level: level, title: title, range: token.range, label: label))
                pendingLabel = nil
            default:
                break
            }
        }
        return result
    }

    /// The last heading at or before `location`, as an index into `headings`.
    public static func headingIndex(at location: Int, in headings: [MystHeading]) -> Int? {
        headings.lastIndex { $0.range.location <= location }
    }
}
