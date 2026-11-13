import AppKit
import MystSyntax

/// Turns MyST tokens into text attributes: a calm theme with directives and roles in one accent
/// colour, math in a second, code on a tinted background and front matter dimmed.
@MainActor
enum MystHighlighter {
    static var settings: EditorSettings { .shared }
    static var baseFont: NSFont { settings.font() }
    static var boldFont: NSFont { settings.font(weight: .bold) }
    static var italicFont: NSFont { settings.font(italic: true) }

    /// Colours from Settings › Editor › Syntax colours.
    static var accent: NSColor { settings.color(.directive) }
    static var mathColor: NSColor { settings.color(.math) }
    static var linkColor: NSColor { settings.color(.link) }
    static var codeBackground: NSColor { settings.color(.codeBackground) }
    static var markerColor: NSColor { settings.color(.marker) }
    static var secondaryColor: NSColor { settings.color(.secondary) }

    /// Line height from the settings, applied to every line.
    static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = CGFloat(settings.lineHeight)
        return style
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraphStyle]
    }

    /// Re-highlights the whole storage. Returns the tokens, so callers can reuse them.
    @discardableResult
    static func highlight(_ storage: NSTextStorage) -> [MystToken] {
        let tokens = MystTokenizer.tokens(in: storage.string)
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: full)
        for token in tokens where NSMaxRange(token.range) <= storage.length {
            let attributes = self.attributes(for: token.kind)
            if !attributes.isEmpty { storage.addAttributes(attributes, range: token.range) }
        }
        storage.endEditing()
        return tokens
    }

    static func attributes(for kind: MystToken.Kind) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .frontMatter, .comment:
            return [.foregroundColor: markerColor]
        case .heading(let level):
            let scale: CGFloat = [1.35, 1.2, 1.1][min(level, 3) - 1]
            return [.font: settings.font(scale: scale, weight: .bold)]
        case .headingMarker, .listMarker, .blockquoteMarker:
            return [.foregroundColor: markerColor]
        case .directiveFence, .directiveOptionKey, .target:
            return [.foregroundColor: accent.withAlphaComponent(0.75)]
        case .directiveName(let name):
            return [.foregroundColor: admonitionColor(name) ?? accent, .font: boldFont]
        case .directiveArgument(let prose):
            return prose ? [.font: boldFont] : [.foregroundColor: secondaryColor]
        case .directiveOptionValue:
            return [.foregroundColor: secondaryColor]
        case .codeFence:
            return [.foregroundColor: secondaryColor, .backgroundColor: codeBackground]
        case .code, .inlineCode:
            return [.backgroundColor: codeBackground]
        case .math, .mathDelimiter:
            return [.foregroundColor: mathColor]
        case .roleName:
            return [.foregroundColor: accent]
        case .roleContent:
            return [.foregroundColor: accent.withAlphaComponent(0.75)]
        case .strong:
            return [.font: boldFont]
        case .emphasis:
            return [.font: italicFont]
        case .linkText:
            return [.foregroundColor: linkColor]
        case .linkTarget, .url:
            return [.foregroundColor: secondaryColor]
        case .substitution, .footnote:
            return [.foregroundColor: accent]
        }
    }

    /// myst.yml opened as text: keys in the accent colour, comments and list markers dimmed,
    /// quoted values grey. Line-based; enough for configuration files.
    static func highlightYAML(_ storage: NSTextStorage) {
        let text = storage.string as NSString
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: NSRange(location: 0, length: text.length))
        let dimmed: [NSAttributedString.Key: Any] = [.foregroundColor: markerColor]
        for match in yamlLine.matches(in: storage.string, range: NSRange(location: 0, length: text.length)) {
            if match.range(at: 1).location != NSNotFound { storage.addAttributes(dimmed, range: match.range(at: 1)) }
            if match.range(at: 2).location != NSNotFound { storage.addAttributes([.foregroundColor: accent], range: match.range(at: 2)) }
        }
        for match in yamlListMarker.matches(in: storage.string, range: NSRange(location: 0, length: text.length)) {
            storage.addAttributes(dimmed, range: match.range(at: 1))
        }
        for match in yamlQuoted.matches(in: storage.string, range: NSRange(location: 0, length: text.length)) {
            storage.addAttributes([.foregroundColor: secondaryColor], range: match.range)
        }
        // Comments last: a `#` at the line start or after a space, outside quotes on simple lines.
        for match in yamlComment.matches(in: storage.string, range: NSRange(location: 0, length: text.length)) {
            storage.setAttributes(baseAttributes.merging(dimmed) { $1 }, range: match.range(at: 1))
        }
        storage.endEditing()
    }

    /// Group 1: list markers; group 2: a key before `:`.
    private static let yamlLine = try! NSRegularExpression(pattern: ##"^\s*((?:-\s+)*)([^\s#'"\-][^:#\n]*?|'[^'\n]*'|"[^"\n]*")?(?=:(?:\s|$))"##, options: .anchorsMatchLines)
    private static let yamlListMarker = try! NSRegularExpression(pattern: #"^\s*(-)(?=\s)"#, options: .anchorsMatchLines)
    private static let yamlQuoted = try! NSRegularExpression(pattern: ##"(?<=:\s|-\s)('[^'\n]*'|"[^"\n]*")"##)
    private static let yamlComment = try! NSRegularExpression(pattern: ##"^(?:[^'"#\n]*?\s)?(#.*)$"##, options: .anchorsMatchLines)

    /// A plugin's JavaScript: keywords in the accent colour, strings grey, comments dimmed.
    static func highlightJavaScript(_ storage: NSTextStorage) {
        let text = storage.string as NSString
        let all = NSRange(location: 0, length: text.length)
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: all)
        for match in jsKeyword.matches(in: storage.string, range: all) {
            storage.addAttributes([.foregroundColor: accent], range: match.range)
        }
        // Strings and comments in one pass, so a quote in a comment (or // in a string) is not misread.
        for match in jsStringOrComment.matches(in: storage.string, range: all) {
            let isComment = text.character(at: match.range.location) == 0x2F // "/"
            storage.setAttributes(baseAttributes.merging([.foregroundColor: isComment ? markerColor : secondaryColor]) { $1 },
                                  range: match.range)
        }
        storage.endEditing()
    }

    /// Other text files: the editor font, nothing else.
    static func highlightPlain(_ storage: NSTextStorage) {
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
    }

    private static let jsKeyword = try! NSRegularExpression(
        pattern: #"\b(?:const|let|var|function|return|export|default|import|from|if|else|for|of|in|async|await|new|class|extends|throw|try|catch|null|undefined|true|false|this)\b"#)
    private static let jsStringOrComment = try! NSRegularExpression(
        pattern: #"//[^\n]*|/\*[\s\S]*?\*/|'(?:\\.|[^'\\\n])*'|"(?:\\.|[^"\\\n])*"|`(?:\\.|[^`\\])*`"#)

    /// Admonitions get a colour by type, like the boxes they become in the book.
    static func admonitionColor(_ name: String) -> NSColor? {
        guard settings.theme == .custom || settings.colorsAdmonitions, let role = SyntaxRole.admonition(name) else { return nil }
        return settings.color(role)
    }
}
