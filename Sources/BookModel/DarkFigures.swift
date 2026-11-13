import Foundation

/// A CSS rule that inverts SVG figures in the site's dark mode, so black line drawings stay
/// readable on a dark background. It lives in the book's stylesheet (`site.options.style`),
/// between marker comments, so it can be switched off again without touching the user's own CSS.
/// The hue is turned back, so colours keep their hue; a figure with `:class: no-invert` is left alone.
public enum DarkFigures {
    static let begin = "/* JupyterBookNook: invert SVG figures in dark mode (switch off in Project settings › Site & theme) */"
    static let end = "/* JupyterBookNook: end */"

    public static let block = """
    \(begin)
    html.dark figure:not(.no-invert) img[src$=".svg"],
    html.dark img.invert-dark {
      filter: invert(1) hue-rotate(180deg);
    }
    \(end)

    """

    /// The stylesheet a book gets when it has none.
    public static let defaultStylesheet = "styles.css"

    public static func isIncluded(in css: String) -> Bool {
        css.contains(begin)
    }

    /// `css` with the block added at the end (unchanged when it is there).
    public static func adding(to css: String) -> String {
        guard !isIncluded(in: css) else { return css }
        let separator = css.isEmpty || css.hasSuffix("\n\n") ? "" : (css.hasSuffix("\n") ? "\n" : "\n\n")
        return css + separator + block
    }

    /// `css` without the block.
    public static func removing(from css: String) -> String {
        guard let start = css.range(of: begin), let stop = css.range(of: end, range: start.upperBound..<css.endIndex) else { return css }
        var upper = stop.upperBound
        while upper < css.endIndex, css[upper] == "\n" { upper = css.index(after: upper) }
        var lower = start.lowerBound
        // Also drop the blank line written before the block.
        while lower > css.startIndex, css[css.index(before: lower)] == "\n",
              lower > css.index(after: css.startIndex), css[css.index(lower, offsetBy: -2)] == "\n" {
            lower = css.index(before: lower)
        }
        var result = css
        result.removeSubrange(lower..<upper)
        return result
    }
}

extension BookProject {
    /// The stylesheet in `site.options.style`, if any.
    public var stylesheet: String? {
        let style = ProjectSettings(yaml: configText).style
        return style.isEmpty ? nil : style
    }

    /// Whether the book's stylesheet has the dark-mode SVG rule.
    public var invertsSVGFiguresInDarkMode: Bool {
        guard let style = stylesheet, let css = try? String(contentsOf: url(for: style), encoding: .utf8) else { return false }
        return DarkFigures.isIncluded(in: css)
    }

    /// Adds or removes the dark-mode SVG rule as one undoable change. Turning it on creates
    /// `styles.css` and lists it in `site.options.style` when the book has no stylesheet; turning it
    /// off removes the rule, and the file and the setting too when nothing else is left in it.
    @discardableResult
    public mutating func setInvertsSVGFiguresInDarkMode(_ on: Bool) throws -> StructuralChange? {
        let style = stylesheet
        let path = style ?? DarkFigures.defaultStylesheet
        let file = url(for: path)
        let existing = try? String(contentsOf: file, encoding: .utf8)
        var operations: [FileOperation] = []
        var config: ((String) throws -> String)?
        if on {
            guard existing.map({ !DarkFigures.isIncluded(in: $0) }) ?? true else { return nil }
            if let existing {
                operations.append(.edited(file, before: existing, after: DarkFigures.adding(to: existing)))
            } else {
                operations.append(.created(file, contents: DarkFigures.block))
            }
            if style == nil { config = { try Self.settingStyle(path, in: $0) } }
        } else {
            guard let existing, DarkFigures.isIncluded(in: existing) else { return nil }
            let remaining = DarkFigures.removing(from: existing)
            if remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                operations.append(.deleted(file, contents: existing))
                config = { try Self.settingStyle(nil, in: $0) }
            } else {
                operations.append(.edited(file, before: existing, after: remaining))
            }
        }
        let summary = on ? "SVG figures are inverted in dark mode — \(path) updated" : "SVG figures are no longer inverted in dark mode"
        return try commit(toc: nil, operations: operations, summary: summary, config: config)
    }

    static func settingStyle(_ path: String?, in text: String) throws -> String {
        let old = ProjectSettings(yaml: text)
        var new = old
        new.style = path ?? ""
        return try new.applying(to: text, from: old)
    }
}
