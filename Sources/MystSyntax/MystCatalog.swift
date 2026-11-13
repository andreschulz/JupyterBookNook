import Foundation

/// The directives and roles MyST (mystmd) knows, with their options and a short description.
/// Used for completion and to flag unknown names; plugins can add more.
public enum MystCatalog {
    public struct Entry: Sendable, Equatable {
        public var name: String
        public var summary: String
        public var options: [String]

        public init(name: String, summary: String, options: [String]) {
            self.name = name
            self.summary = summary
            self.options = options
        }
    }

    static let admonitionOptions = ["label", "class", "open", "icon"]
    static let proofOptions = ["label", "class", "nonumber"]

    public static let directives: [Entry] = {
        var list: [Entry] = [
            Entry(name: "admonition", summary: "A callout box with your own title", options: admonitionOptions),
            Entry(name: "figure", summary: "An image with a caption, numbered and referenceable", options: ["label", "name", "width", "height", "align", "alt", "class", "kind", "placeholder"]),
            Entry(name: "image", summary: "An image without a caption", options: ["label", "name", "width", "height", "align", "alt", "class", "title"]),
            Entry(name: "table", summary: "A Markdown table with a caption", options: ["label", "name", "class", "align"]),
            Entry(name: "list-table", summary: "A table written as nested lists", options: ["label", "name", "header-rows", "stub-columns", "widths", "width", "align", "class"]),
            Entry(name: "csv-table", summary: "A table from comma-separated values", options: ["label", "name", "header", "header-rows", "widths", "delim", "class"]),
            Entry(name: "code", summary: "Highlighted code", options: ["label", "name", "linenos", "lineno-start", "emphasize-lines", "caption", "filename", "class"]),
            Entry(name: "code-block", summary: "Highlighted code (same as code)", options: ["label", "name", "linenos", "lineno-start", "emphasize-lines", "caption", "filename", "class"]),
            Entry(name: "code-cell", summary: "An executable notebook cell", options: ["tags", "label", "caption"]),
            Entry(name: "math", summary: "Display math, numbered and referenceable", options: ["label", "name", "enumerated"]),
            Entry(name: "include", summary: "Include another file", options: ["literal", "lang", "start-line", "end-line", "start-at", "start-after", "end-at", "end-before", "lines", "caption", "filename", "linenos", "label"]),
            Entry(name: "literalinclude", summary: "Include a file as code", options: ["lang", "start-line", "end-line", "start-at", "start-after", "end-at", "end-before", "lines", "caption", "filename", "linenos", "emphasize-lines", "label"]),
            Entry(name: "embed", summary: "Embed content by its label, from this or another page", options: ["remove-input", "remove-output"]),
            Entry(name: "iframe", summary: "An embedded web page or video", options: ["width", "align", "label", "class", "placeholder"]),
            Entry(name: "glossary", summary: "Terms and definitions for the {term} role", options: []),
            Entry(name: "aside", summary: "Content beside the main text", options: ["class"]),
            Entry(name: "margin", summary: "Content in the margin", options: ["class"]),
            Entry(name: "sidebar", summary: "Content in a sidebar", options: ["class"]),
            Entry(name: "topic", summary: "A self-contained topic box", options: ["class"]),
            Entry(name: "blockquote", summary: "A quotation", options: ["class"]),
            Entry(name: "epigraph", summary: "A quotation at the start of a section", options: ["class"]),
            Entry(name: "pull-quote", summary: "A pulled-out quotation", options: ["class"]),
            Entry(name: "tab-set", summary: "A set of tabs", options: ["class", "sync-group"]),
            Entry(name: "tab-item", summary: "One tab in a tab-set", options: ["sync", "selected", "class"]),
            Entry(name: "card", summary: "A card with optional header, footer and link", options: ["header", "footer", "link", "class"]),
            Entry(name: "grid", summary: "A grid of cards", options: ["class"]),
            Entry(name: "grid-item", summary: "One item in a grid", options: ["class"]),
            Entry(name: "grid-item-card", summary: "A card in a grid", options: ["header", "footer", "link", "class"]),
            Entry(name: "dropdown", summary: "A collapsible block", options: ["open", "class", "icon"]),
            Entry(name: "mermaid", summary: "A Mermaid diagram", options: ["label", "caption"]),
            Entry(name: "raw", summary: "Raw output for one format", options: []),
            Entry(name: "div", summary: "A block with a class", options: ["class", "label"]),
            Entry(name: "toc", summary: "A table of contents", options: ["context", "depth"]),
            Entry(name: "exercise", summary: "A numbered exercise", options: ["label", "class", "nonumber", "hidden"]),
            Entry(name: "solution", summary: "The solution to an exercise", options: ["label", "class", "hidden"]),
            Entry(name: "proof", summary: "A proof", options: proofOptions),
        ]
        for (name, summary) in [("note", "A note"), ("tip", "A tip"), ("hint", "A hint"), ("important", "Something important"),
                                ("seealso", "Related material"), ("attention", "Something to pay attention to"),
                                ("caution", "A caution"), ("warning", "A warning"), ("danger", "A danger"), ("error", "An error")] {
            list.append(Entry(name: name, summary: "Admonition: \(summary.lowercased())", options: admonitionOptions))
        }
        for kind in ["theorem", "lemma", "definition", "corollary", "proposition", "conjecture", "axiom", "criterion",
                     "remark", "example", "property", "observation", "assumption", "algorithm", "notation", "proof"] {
            list.append(Entry(name: "prf:\(kind)", summary: "A numbered \(kind)", options: proofOptions))
        }
        return list
    }()

    public static let roles: [Entry] = [
        Entry(name: "ref", summary: "Cross-reference by label, shown with the target's title", options: []),
        Entry(name: "numref", summary: "Numbered cross-reference, e.g. “Figure 2”", options: []),
        Entry(name: "eq", summary: "Reference to a numbered equation", options: []),
        Entry(name: "doc", summary: "Link to another page by its file", options: []),
        Entry(name: "term", summary: "Link to a glossary term", options: []),
        Entry(name: "cite", summary: "Citation from the bibliography", options: []),
        Entry(name: "cite:p", summary: "Parenthetical citation (Author, Year)", options: []),
        Entry(name: "cite:t", summary: "Textual citation Author (Year)", options: []),
        Entry(name: "cite:ps", summary: "Parenthetical citation, all authors", options: []),
        Entry(name: "cite:ts", summary: "Textual citation, all authors", options: []),
        Entry(name: "math", summary: "Inline math", options: []),
        Entry(name: "abbr", summary: "Abbreviation with its expansion: {abbr}`MyST (Markedly Structured Text)`", options: []),
        Entry(name: "sub", summary: "Subscript", options: []),
        Entry(name: "subscript", summary: "Subscript", options: []),
        Entry(name: "sup", summary: "Superscript", options: []),
        Entry(name: "superscript", summary: "Superscript", options: []),
        Entry(name: "u", summary: "Underline", options: []),
        Entry(name: "underline", summary: "Underline", options: []),
        Entry(name: "del", summary: "Strikethrough", options: []),
        Entry(name: "strike", summary: "Strikethrough", options: []),
        Entry(name: "smallcaps", summary: "Small capitals", options: []),
        Entry(name: "kbd", summary: "A keyboard key", options: []),
        Entry(name: "download", summary: "A link that downloads a file", options: []),
        Entry(name: "button", summary: "A link shown as a button", options: []),
        Entry(name: "span", summary: "Inline text with a class", options: []),
        Entry(name: "raw", summary: "Raw inline output", options: []),
    ]

    public static func directive(_ name: String) -> Entry? { directives.first { $0.name == name } }
    public static func role(_ name: String) -> Entry? { roles.first { $0.name == name } }

    /// Roles whose content is a label, and the kinds of label each accepts (nil: any).
    public static let labelRoles: [String: Set<LabelKind>?] = [
        "ref": nil,
        "numref": [.figure, .table, .code, .equation, .theorem, .exercise, .heading],
        "eq": [.equation],
    ]
    public static let citationRoles: Set<String> = ["cite", "cite:p", "cite:t", "cite:ps", "cite:ts"]
}

/// What a label points to.
public enum LabelKind: String, Sendable, Hashable, CaseIterable {
    case heading, page, figure, table, code, equation, theorem, exercise, target, other

    /// The kind of label a directive's `:label:` creates.
    public static func forDirective(_ name: String) -> LabelKind {
        switch name {
        case "figure", "image", "iframe", "mermaid": return .figure
        case "table", "list-table", "csv-table": return .table
        case "code", "code-block", "code-cell", "literalinclude", "sourcecode": return .code
        case "math": return .equation
        case "exercise", "solution": return .exercise
        default: return name.hasPrefix("prf:") || name == "proof" ? .theorem : .other
        }
    }
}
