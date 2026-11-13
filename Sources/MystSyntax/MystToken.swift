import Foundation

/// A highlighted span of MyST Markdown. Ranges are UTF-16 based (`NSRange`), as `NSTextView` uses.
public struct MystToken: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case frontMatter
        case headingMarker
        case heading(level: Int)
        case directiveFence
        case directiveName(String)
        /// The text after `{name}`; `prose` for titles such as `{note} Choosing the step size`,
        /// not for paths or code languages.
        case directiveArgument(prose: Bool)
        case directiveOptionKey
        case directiveOptionValue
        case codeFence
        case code
        case mathDelimiter
        case math
        case roleName(String)
        case roleContent
        case inlineCode
        case target
        case comment
        case listMarker
        case blockquoteMarker
        case strong
        case emphasis
        case linkText
        case linkTarget
        case url
        case substitution
        case footnote
    }

    public var kind: Kind
    public var range: NSRange

    public init(_ kind: Kind, _ range: NSRange) {
        self.kind = kind
        self.range = range
    }

    /// Prose tokens keep spell checking; code, math, directive syntax, roles, labels and URLs do not.
    /// Text that no token covers is prose too.
    public var checksSpelling: Bool {
        switch kind {
        case .heading, .strong, .emphasis, .linkText, .listMarker, .blockquoteMarker: return true
        case .directiveArgument(let prose): return prose
        default: return false
        }
    }
}

/// Directive names whose bodies are code, math, or whose argument is not prose.
public enum MystDirectives {
    public static let code: Set<String> = ["code", "code-block", "code-cell", "sourcecode", "literalinclude"]
    public static let math: Set<String> = ["math"]
    /// Directives whose argument is a path, a language or a label rather than a title.
    public static let nonProseArgument: Set<String> = code.union([
        "include", "figure", "image", "embed", "literalinclude", "bibliography", "glossary", "mermaid", "iframe", "csv-table",
    ])
    /// Admonition directives, used to colour their fences by type.
    public static let admonitions: Set<String> = [
        "admonition", "note", "tip", "hint", "important", "seealso", "attention", "caution", "warning", "danger", "error",
    ]
}
