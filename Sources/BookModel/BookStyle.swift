import Foundation

/// The look of a book's website, edited in the Style screen and written to the book's stylesheet
/// (`site.options.style`). The editor owns the part of the file between two marker comments: a
/// small sheet of plain rules, read back into `rules`. Everything else in the file (CSS of the
/// user's own, the dark-figures rule) is kept in `custom`, below the editor's part, so it wins.
public struct BookStyle: Equatable, Sendable {
    public struct Declaration: Equatable, Sendable {
        public var property: String
        public var value: String
    }

    public struct Rule: Equatable, Sendable {
        public var selector: String
        public var declarations: [Declaration]
    }

    /// The style's name, shown in the editor and used when saving it to the library.
    public var name: String
    public var rules: [Rule]
    /// CSS outside the editor's part, kept as it is.
    public var custom: String

    static let beginMarker = "/* nook-style begin"
    static let endMarker = "/* nook-style end */"

    public init(name: String = "", rules: [Rule] = [], custom: String = "") {
        self.name = name
        self.rules = rules
        self.custom = custom
    }

    /// Reads a stylesheet. A file without the editor's markers is all `custom`.
    public init(css: String) {
        self.init()
        guard let begin = css.range(of: Self.beginMarker),
              let beginLineEnd = css.range(of: "*/", range: begin.upperBound..<css.endIndex),
              let end = css.range(of: Self.endMarker, range: beginLineEnd.upperBound..<css.endIndex) else {
            custom = css
            return
        }
        name = css[begin.upperBound..<beginLineEnd.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespaces))
        rules = Self.ordered(Self.parseRules(String(css[beginLineEnd.upperBound..<end.lowerBound])))
        // CSS before the editor's part (other than its own header comment) moves below it:
        // @import lines must come first in a stylesheet.
        let before = Self.removingHeader(String(css[..<begin.lowerBound])).trimmingCharacters(in: .whitespacesAndNewlines)
        let after = String(css[end.upperBound...]).trimmingCharacters(in: .newlines)
        custom = [before, after].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The whole stylesheet: a header, the editor's part, then the custom CSS.
    public var css: String {
        var lines: [String] = []
        lines.append("/* The book's style, made with JupyterBookNook's style editor (sidebar › Project › Style).")
        lines.append("   The editor rewrites everything from “nook-style begin” to “nook-style end”;")
        lines.append("   CSS of your own goes below that and is kept as it is. */")
        lines.append(Self.beginMarker + (name.isEmpty ? "" : ": " + name) + " */")
        for font in webFonts {
            lines.append("@import url('\(font.importURL)');")
        }
        for rule in rules where !rule.declarations.isEmpty {
            lines.append(rule.selector + " {")
            for declaration in rule.declarations {
                lines.append("  \(declaration.property): \(declaration.value);")
            }
            lines.append("}")
        }
        lines.append(Self.endMarker)
        var text = lines.joined(separator: "\n") + "\n"
        let custom = custom.trimmingCharacters(in: .newlines)
        if !custom.isEmpty { text += "\n" + custom + "\n" }
        return text
    }

    /// Whether the editor's part sets anything.
    public var isEmpty: Bool { rules.allSatisfy(\.declarations.isEmpty) }

    // MARK: Values

    public subscript(selector: String, property: String) -> String? {
        get {
            rules.first { $0.selector == selector }?.declarations.first { $0.property == property }?.value
        }
        set {
            let value = newValue?.trimmingCharacters(in: .whitespaces)
            if let index = rules.firstIndex(where: { $0.selector == selector }) {
                var declarations = rules[index].declarations
                if let at = declarations.firstIndex(where: { $0.property == property }) {
                    if let value, !value.isEmpty { declarations[at].value = value } else { declarations.remove(at: at) }
                } else if let value, !value.isEmpty {
                    declarations.append(Declaration(property: property, value: value))
                }
                if declarations.isEmpty { rules.remove(at: index) } else { rules[index].declarations = declarations }
            } else if let value, !value.isEmpty {
                rules.append(Rule(selector: selector, declarations: [Declaration(property: property, value: value)]))
                rules = Self.ordered(rules)
            }
        }
    }

    /// The CSS value of a control (nil for myst.yml settings, which the book holds).
    public func value(_ control: StyleControl, dark: Bool = false) -> String? {
        guard !control.kind.isConfig else { return nil }
        return self[control.selector(dark: dark), control.property]
    }

    public mutating func set(_ control: StyleControl, to value: String?, dark: Bool = false) {
        guard !control.kind.isConfig else { return }
        self[control.selector(dark: dark), control.property] = value
    }

    /// Whether anything of `element` is set in the stylesheet.
    public func isSet(_ element: StyleElement) -> Bool {
        element.controls.contains { value($0) != nil || ($0.kind.isColor && value($0, dark: true) != nil) }
    }

    /// Clears the element's CSS; its myst.yml settings stay.
    public mutating func reset(_ element: StyleElement) {
        for control in element.controls where !control.kind.isConfig {
            set(control, to: nil)
            if control.kind.isColor { set(control, to: nil, dark: true) }
        }
    }

    /// Web fonts used anywhere in the rules, each imported once from Google Fonts.
    public var webFonts: [StyleFont] {
        var seen: [StyleFont] = []
        for rule in rules {
            for declaration in rule.declarations where declaration.property == "font-family" {
                if let font = StyleFont.matching(declaration.value), font.googleFamily != nil, !seen.contains(font) { seen.append(font) }
            }
        }
        return seen
    }

    /// Every selector the editor's elements use, in their order.
    private static let selectorOrder: [String] = {
        var order: [String] = []
        for element in StyleElement.all {
            for control in element.controls where !control.kind.isConfig {
                for selector in [control.selector(dark: false)] + (control.kind.isColor ? [control.selector(dark: true)] : []) where !order.contains(selector) {
                    order.append(selector)
                }
            }
        }
        return order
    }()

    /// Rules in the order of the editor's elements, then any others as they were (a stable sort).
    static func ordered(_ rules: [Rule]) -> [Rule] {
        rules.enumerated().sorted { a, b in
            let ia = selectorOrder.firstIndex(of: a.element.selector) ?? Int.max
            let ib = selectorOrder.firstIndex(of: b.element.selector) ?? Int.max
            return ia != ib ? ia < ib : a.offset < b.offset
        }.map(\.element)
    }

    // MARK: Library

    /// This style taken into a book whose current style is `current`: the rules and name are
    /// replaced; the book's own CSS stays, and the style's own CSS is added when it is not there yet.
    public func loaded(into current: BookStyle) -> BookStyle {
        var result = current
        result.name = name
        result.rules = rules
        let incoming = DarkFigures.removing(from: custom).trimmingCharacters(in: .whitespacesAndNewlines)
        if !incoming.isEmpty, !current.custom.contains(incoming) {
            result.custom = [current.custom.trimmingCharacters(in: .newlines), incoming].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        return result
    }

    /// The stylesheet as kept in the library: without the dark-figures rule, which is a setting of each book.
    public var libraryCSS: String {
        var copy = self
        copy.custom = DarkFigures.removing(from: custom)
        return copy.css
    }

    // MARK: Parsing

    private static func removingHeader(_ text: String) -> String {
        guard let start = text.range(of: "/* The book's style, made with JupyterBookNook"),
              let end = text.range(of: "*/", range: start.upperBound..<text.endIndex) else { return text }
        var result = text
        result.removeSubrange(start.lowerBound..<end.upperBound)
        return result
    }

    /// Plain `selector { property: value; … }` rules; comments and @-rules are skipped.
    static func parseRules(_ text: String) -> [Rule] {
        let chars = Array(stripComments(text))
        var rules: [Rule] = []
        var i = 0
        while i < chars.count {
            if chars[i].isWhitespace {
                i += 1
                continue
            }
            // An @-statement (@import …;) is skipped up to its semicolon.
            if chars[i] == "@" {
                var quote: Character?
                while i < chars.count {
                    let c = chars[i]
                    if let q = quote {
                        if c == q { quote = nil }
                    } else if c == "\"" || c == "'" {
                        quote = c
                    } else if c == ";" || c == "{" {
                        break
                    }
                    i += 1
                }
                if i < chars.count, chars[i] == "{" { i = skipBlock(chars, from: i) } else { i += 1 }
                continue
            }
            guard let open = chars[i...].firstIndex(of: "{") else { break }
            let selector = String(chars[i..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let close = skipBlock(chars, from: open)
            let body = String(chars[(open + 1)..<max(open + 1, close - 1)])
            if !selector.isEmpty {
                let declarations = splitDeclarations(body).compactMap { part -> Declaration? in
                    guard let colon = part.firstIndex(of: ":") else { return nil }
                    let property = part[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
                    let value = part[part.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
                    return property.isEmpty || value.isEmpty ? nil : Declaration(property: property, value: value)
                }
                if let index = rules.firstIndex(where: { $0.selector == selector }) {
                    rules[index].declarations += declarations
                } else {
                    rules.append(Rule(selector: selector, declarations: declarations))
                }
            }
            i = close
        }
        return rules
    }

    /// Index after the block whose `{` is at `open`.
    private static func skipBlock(_ chars: [Character], from open: Int) -> Int {
        var depth = 0
        var quote: Character?
        var i = open
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if c == "\\" { i += 1 } else if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 { return i + 1 }
            }
            i += 1
        }
        return chars.count
    }

    /// Splits at semicolons outside quotes and parentheses (url(…), var(…)).
    private static func splitDeclarations(_ body: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        for c in body {
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "(" {
                depth += 1
            } else if c == ")" {
                depth -= 1
            } else if c == ";", depth == 0 {
                parts.append(current)
                current = ""
                continue
            }
            current.append(c)
        }
        parts.append(current)
        return parts
    }

    private static func stripComments(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let start = rest.range(of: "/*") {
            result += rest[..<start.lowerBound]
            guard let end = rest.range(of: "*/", range: start.upperBound..<rest.endIndex) else { return result }
            rest = rest[end.upperBound...]
        }
        return result + rest
    }
}

// MARK: - Elements

/// One setting of an element: a CSS property of a selector. Colours have a value for light and
/// one for dark mode; MyST's themes switch with the `dark` class on `<html>`.
public struct StyleControl: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case font
        /// A number with a unit, from a slider.
        case number(unit: String, range: ClosedRange<Double>, step: Double)
        case color
        case choice([Choice])
        /// A text setting in myst.yml (`property` is its dotted path), e.g. the site name.
        case configText(placeholder: String, multiline: Bool)
        /// A true/false setting in myst.yml (`property` is its dotted path).
        case configFlag

        public var isColor: Bool { self == .color }
        public var isConfig: Bool {
            switch self {
            case .configText, .configFlag: return true
            default: return false
            }
        }
    }

    public struct Choice: Hashable, Sendable {
        public let label: String
        public let value: String
        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    public let label: String
    /// The selector for non-colours, and the element part of colours ("" for a theme variable).
    public let base: String
    public let property: String
    public let kind: Kind
    public var help: String?

    public var id: String { base + "|" + property }

    /// The myst.yml path of a config setting.
    public var configPath: [String] { property.split(separator: ".").map(String.init) }

    /// A setting written to myst.yml instead of the stylesheet.
    public static func config(_ label: String, _ path: String, _ kind: Kind, help: String? = nil) -> StyleControl {
        StyleControl(label, "", path, kind, help: help)
    }

    public init(_ label: String, _ base: String, _ property: String, _ kind: Kind, help: String? = nil) {
        self.label = label
        self.base = base
        self.property = property
        self.kind = kind
        self.help = help
    }

    /// Light and dark colours are written for `html:not(.dark)` and `html.dark`, which outrank the
    /// theme's own `:root` and `.dark` rules whatever the order.
    public func selector(dark: Bool) -> String {
        guard kind.isColor else { return base }
        let mode = dark ? "html.dark" : "html:not(.dark)"
        return base.isEmpty ? mode : mode + " " + base
    }
}

/// A part of the page the editor styles, with the settings it offers. The selectors follow the
/// HTML of MyST's book and article themes (mystmd 1.11): the page text is `article.article`.
public struct StyleElement: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let symbol: String
    public let summary: String
    public let controls: [StyleControl]

    static let text = "article.article"

    static func size(_ base: String, unit: String = "em", _ range: ClosedRange<Double>, step: Double = 0.05, label: String = "Size") -> StyleControl {
        StyleControl(label, base, "font-size", .number(unit: unit, range: range, step: step))
    }

    static let weights: StyleControl.Kind = .choice([.init("Regular", "400"), .init("Medium", "500"), .init("Semibold", "600"), .init("Bold", "700"), .init("Black", "900")])
    static let styles: StyleControl.Kind = .choice([.init("Upright", "normal"), .init("Italic", "italic")])
    static let alignments: StyleControl.Kind = .choice([.init("Left", "left"), .init("Centred", "center"), .init("Right", "right")])
    static let variants: StyleControl.Kind = .choice([.init("Normal", "normal"), .init("Small capitals", "small-caps")])

    static func heading(_ level: Int, size: ClosedRange<Double>) -> StyleElement {
        let base = "\(text) h\(level)"
        return StyleElement(id: "h\(level)", name: "Heading \(level)", symbol: "textformat.size", summary: "\(String(repeating: "#", count: level)) headings in the page text.", controls: [
            StyleControl("Font", base, "font-family", .font),
            Self.size(base, size),
            StyleControl("Weight", base, "font-weight", weights),
            StyleControl("Style", base, "font-style", styles),
            StyleControl("Letters", base, "font-variant", variants),
            StyleControl("Colour", base, "color", .color),
            StyleControl("Alignment", base, "text-align", alignments),
            StyleControl("Space above", base, "margin-top", .number(unit: "em", range: 0...4, step: 0.1)),
        ])
    }

    public static let all: [StyleElement] = [
        StyleElement(id: "text", name: "Page text", symbol: "text.alignleft", summary: "Paragraphs, lists and everything else in a page that has no setting of its own.", controls: [
            StyleControl("Font", text, "font-family", .font),
            size(text, unit: "px", 13...24, step: 0.5),
            StyleControl("Line height", text, "line-height", .number(unit: "", range: 1.1...2.2, step: 0.05)),
            StyleControl("Colour", "", "--myst-color-prose-body", .color),
            StyleControl("Alignment", "\(text) p", "text-align", .choice([.init("Left", "left"), .init("Justified", "justify")])),
            StyleControl("Hyphenation", "\(text) p", "hyphens", .choice([.init("Off", "manual"), .init("Automatic", "auto")]),
                         help: "Breaks long words at the line end, in the page's language. Best with justified text."),
        ]),
        StyleElement(id: "title", name: "Page title", symbol: "textformat", summary: "The title at the top of each page, from its front matter.", controls: [
            StyleControl("Font", ".myst-fm-block-title", "font-family", .font),
            size(".myst-fm-block-title", unit: "px", 20...60, step: 1),
            StyleControl("Weight", ".myst-fm-block-title", "font-weight", weights),
            StyleControl("Letters", ".myst-fm-block-title", "font-variant", variants),
            StyleControl("Colour", ".myst-fm-block-title", "color", .color),
            StyleControl("Alignment", ".myst-fm-block-title", "text-align", alignments),
        ]),
        heading(1, size: 1...3.5),
        heading(2, size: 1...3),
        heading(3, size: 0.9...2.5),
        StyleElement(id: "links", name: "Links", symbol: "link", summary: "Links and cross-references in the page text.", controls: [
            StyleControl("Colour", "", "--myst-color-link", .color),
            StyleControl("Underline colour", "", "--myst-color-link-underline", .color),
            StyleControl("Hover colour", "", "--myst-color-link-hover", .color),
            StyleControl("Underline", "\(text) a", "text-decoration-line", .choice([.init("Underlined", "underline"), .init("None", "none")])),
            StyleControl("Weight", "\(text) a", "font-weight", .choice([.init("Regular", "400"), .init("Medium", "500"), .init("Semibold", "600")])),
        ]),
        StyleElement(id: "code", name: "Inline code", symbol: "chevron.left.forwardslash.chevron.right", summary: "`Code` within a sentence.", controls: [
            StyleControl("Font", "\(text) :not(pre) > code", "font-family", .font),
            size("\(text) :not(pre) > code", 0.7...1.2),
            StyleControl("Colour", "", "--myst-color-code", .color),
            StyleControl("Background", "\(text) :not(pre) > code", "background-color", .color),
        ]),
        StyleElement(id: "codeblocks", name: "Code blocks", symbol: "curlybraces", summary: "Fenced code and {code} blocks.", controls: [
            StyleControl("Font", "\(text) .myst-code code", "font-family", .font),
            size("\(text) .myst-code", unit: "px", 11...18, step: 0.5),
            StyleControl("Background", "\(text) .myst-code", "background-color", .color),
            StyleControl("Line colour", "\(text) .myst-code", "border-left-color", .color, help: "The line at the left of the block."),
            StyleControl("Corners", "\(text) .myst-code", "border-radius", .number(unit: "px", range: 0...16, step: 1)),
        ]),
        StyleElement(id: "admonitions", name: "Boxes", symbol: "exclamationmark.bubble", summary: "Admonitions: {note}, {tip}, {warning} and the others. Their colours come from the box type.", controls: [
            StyleControl("Background", "\(text) .myst-admonition", "background-color", .color),
            StyleControl("Corners", "\(text) .myst-admonition", "border-radius", .number(unit: "px", range: 0...16, step: 1)),
            StyleControl("Line width", "\(text) .myst-admonition", "border-left-width", .number(unit: "px", range: 0...10, step: 1), help: "The coloured line at the left of the box."),
            StyleControl("Shadow", "\(text) .myst-admonition", "box-shadow", .choice([.init("None", "none")])),
            StyleControl("Title font", "\(text) .myst-admonition-header", "font-family", .font),
            StyleControl("Title weight", "\(text) .myst-admonition-header", "font-weight", weights),
            size("\(text) .myst-admonition-body", 0.8...1.1, label: "Text size"),
        ]),
        StyleElement(id: "captions", name: "Figure captions", symbol: "photo", summary: "Captions of figures and tables.", controls: [
            StyleControl("Font", "\(text) figcaption", "font-family", .font),
            size("\(text) figcaption", 0.7...1.2),
            StyleControl("Style", "\(text) figcaption", "font-style", styles),
            StyleControl("Colour", "\(text) figcaption", "color", .color),
            StyleControl("Alignment", "\(text) figcaption", "text-align", alignments),
        ]),
        StyleElement(id: "quotes", name: "Quotes", symbol: "text.quote", summary: "> block quotes.", controls: [
            StyleControl("Font", "\(text) blockquote", "font-family", .font),
            size("\(text) blockquote", 0.8...1.4),
            StyleControl("Style", "\(text) blockquote", "font-style", styles),
            StyleControl("Colour", "\(text) blockquote", "color", .color),
            StyleControl("Line colour", "\(text) blockquote", "border-left-color", .color),
        ]),
        StyleElement(id: "tables", name: "Tables", symbol: "tablecells", summary: "Tables in the page text.", controls: [
            size("\(text) table", 0.7...1.1),
            StyleControl("Header background", "\(text) thead th", "background-color", .color),
            StyleControl("Header weight", "\(text) thead th", "font-weight", weights),
        ]),
        StyleElement(id: "site", name: "Site colours", symbol: "paintpalette", summary: "Colours of the whole site, including the navigation.", controls: [
            StyleControl("Background", "", "--myst-color-bg", .color),
            StyleControl("Text and headings", "", "--myst-color-text", .color),
            StyleControl("Accent", "", "--myst-color-primary", .color, help: "Buttons and highlights."),
            StyleControl("Current page", "", "--myst-color-active", .color, help: "The current page in the table of contents."),
        ]),
        StyleElement(id: "topbar", name: "Top bar", symbol: "menubar.rectangle", summary: "The bar at the top of every page, with the site name, search and the light/dark switch.", controls: [
            .config("Site name", "site.options.logo_text", .configText(placeholder: "Made with MyST", multiline: false),
                    help: "Shown at the top left (site.options.logo_text). Without it MyST shows “Made with MyST”."),
            StyleControl("Name font", ".myst-home-link span", "font-family", .font),
            size(".myst-home-link span", unit: "px", 12...32, step: 1, label: "Name size"),
            StyleControl("Name weight", ".myst-home-link span", "font-weight", weights),
            StyleControl("Name colour", ".myst-home-link", "color", .color),
            StyleControl("Background", ".myst-top-nav", "background-color", .color),
            StyleControl("Shadow", ".myst-top-nav", "box-shadow", .choice([.init("None", "none")])),
            .config("Hide search", "site.options.hide_search", .configFlag),
        ]),
        StyleElement(id: "toc", name: "Table of contents", symbol: "sidebar.left", summary: "The list of pages at the left.", controls: [
            .config("Hide table of contents", "site.options.hide_toc", .configFlag),
            StyleControl("Font", ".myst-primary-sidebar", "font-family", .font),
            size(".myst-primary-sidebar-nav", unit: "px", 11...20, step: 0.5),
        ]),
        StyleElement(id: "madewith", name: "Made with MyST", symbol: "seal", summary: "The “Made with MyST” link at the bottom of the table of contents.", controls: [
            StyleControl("Visibility", ".myst-made-with-myst", "display", .choice([.init("Hidden", "none")])),
            StyleControl("Colour", ".myst-made-with-myst", "color", .color),
            .config("Replace with", "site.parts.primary_sidebar_footer", .configText(placeholder: "Markdown, e.g. © 2026 The Authors", multiline: true),
                    help: "Your own text instead of “Made with MyST” (site.parts.primary_sidebar_footer)."),
            size(".myst-primary-sidebar-footer", 0.7...1.2, label: "Text size"),
        ]),
        StyleElement(id: "footerlinks", name: "Previous and next", symbol: "arrow.left.arrow.right", summary: "The links to the previous and next page below the text.", controls: [
            .config("Hide them", "site.options.hide_footer_links", .configFlag),
            StyleControl("Corners", ".myst-footer-link", "border-radius", .number(unit: "px", range: 0...16, step: 1)),
            StyleControl("Shadow", ".myst-footer-link", "box-shadow", .choice([.init("None", "none")])),
            StyleControl("Border colour", ".myst-footer-link", "border-color", .color),
        ]),
        StyleElement(id: "footer", name: "Page footer", symbol: "rectangle.bottomthird.inset.filled", summary: "Text at the bottom of every page (site.parts.footer), e.g. a copyright line or links.", controls: [
            .config("Text", "site.parts.footer", .configText(placeholder: "Markdown, e.g. © 2026 The Authors · [Imprint](imprint.md)", multiline: true)),
            size("footer.footer", 0.7...1.2),
            StyleControl("Alignment", "footer.footer", "text-align", alignments),
            StyleControl("Colour", "footer.footer", "color", .color),
            StyleControl("Background", "footer.footer", "background-color", .color),
            StyleControl("Shadow", "footer.footer", "box-shadow", .choice([.init("None", "none")])),
        ]),
        StyleElement(id: "outline", name: "Page outline", symbol: "list.bullet.indent", summary: "The headings of the page at the right.", controls: [
            .config("Hide the outline", "site.options.hide_outline", .configFlag),
        ]),
    ]

    public static func named(_ id: String) -> StyleElement? { all.first { $0.id == id } }
}

// MARK: - Fonts

/// A font the editor offers: a local stack, or a Google font (imported by the stylesheet).
public struct StyleFont: Identifiable, Hashable, Sendable {
    public let name: String
    public let stack: String
    /// The family on Google Fonts, for web fonts.
    public let googleFamily: String?

    public var id: String { name }

    public var importURL: String {
        let family = (googleFamily ?? name).replacingOccurrences(of: " ", with: "+")
        return "https://fonts.googleapis.com/css2?family=\(family):ital,wght@0,400;0,600;0,700;1,400&display=swap"
    }

    public static let local: [StyleFont] = [
        StyleFont(name: "System sans-serif", stack: "ui-sans-serif, system-ui, -apple-system, \"Segoe UI\", Roboto, sans-serif", googleFamily: nil),
        StyleFont(name: "Book serif", stack: "\"Iowan Old Style\", \"Palatino Linotype\", Palatino, Georgia, serif", googleFamily: nil),
        StyleFont(name: "Times", stack: "\"Times New Roman\", Times, serif", googleFamily: nil),
        StyleFont(name: "Humanist sans", stack: "\"Gill Sans\", \"Gill Sans MT\", Calibri, \"Trebuchet MS\", sans-serif", googleFamily: nil),
        StyleFont(name: "Monospace", stack: "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace", googleFamily: nil),
    ]

    static func google(_ family: String, _ fallback: String) -> StyleFont {
        StyleFont(name: family, stack: "\"\(family)\", \(fallback)", googleFamily: family)
    }

    /// Loaded from Google Fonts by the readers' browsers.
    public static let web: [StyleFont] = [
        google("Source Serif 4", "Georgia, serif"),
        google("Merriweather", "Georgia, serif"),
        google("Lora", "Georgia, serif"),
        google("EB Garamond", "Garamond, Georgia, serif"),
        google("Libre Baskerville", "Baskerville, Georgia, serif"),
        google("Inter", "ui-sans-serif, system-ui, sans-serif"),
        google("Source Sans 3", "ui-sans-serif, system-ui, sans-serif"),
        google("IBM Plex Sans", "ui-sans-serif, system-ui, sans-serif"),
        google("Fira Sans", "ui-sans-serif, system-ui, sans-serif"),
        google("Roboto Slab", "Rockwell, Georgia, serif"),
        google("JetBrains Mono", "ui-monospace, Menlo, monospace"),
        google("Fira Code", "ui-monospace, Menlo, monospace"),
    ]

    public static let all = local + web

    /// The offered font with this CSS value, if it is one.
    public static func matching(_ value: String) -> StyleFont? {
        let normal = value.replacingOccurrences(of: "'", with: "\"").trimmingCharacters(in: .whitespaces)
        return all.first { $0.stack == normal }
    }
}

// MARK: - Built-in styles

extension BookStyle {
    private static func make(_ name: String, _ values: [(String, String, String?, String?)]) -> BookStyle {
        var style = BookStyle(name: name)
        for (elementID, label, light, dark) in values {
            guard let control = StyleElement.named(elementID)?.controls.first(where: { $0.label == label }) else {
                assertionFailure("no control \(elementID).\(label)")
                continue
            }
            style.set(control, to: light)
            if let dark { style.set(control, to: dark, dark: true) }
        }
        return style
    }

    private static func font(_ name: String) -> String { StyleFont.all.first { $0.name == name }!.stack }

    /// Styles to start from, offered with the user's own.
    public static let builtIn: [BookStyle] = [
        BookStyle(name: "Theme default"),
        make("Classic book", [
            ("text", "Font", font("Book serif"), nil), ("text", "Size", "18px", nil), ("text", "Line height", "1.65", nil),
            ("text", "Alignment", "justify", nil), ("text", "Hyphenation", "auto", nil),
            ("title", "Font", font("Book serif"), nil), ("title", "Weight", "400", nil), ("title", "Alignment", "center", nil),
            ("h1", "Font", font("Book serif"), nil), ("h1", "Weight", "600", nil),
            ("h2", "Font", font("Book serif"), nil), ("h2", "Weight", "600", nil),
            ("h3", "Font", font("Book serif"), nil), ("h3", "Weight", "600", nil), ("h3", "Style", "italic", nil),
            ("captions", "Style", "italic", nil), ("captions", "Alignment", "center", nil),
            ("quotes", "Style", "italic", nil),
            ("admonitions", "Shadow", "none", nil),
        ]),
        make("Modern", [
            ("text", "Font", font("Inter"), nil), ("text", "Size", "17px", nil), ("text", "Line height", "1.7", nil),
            ("title", "Font", font("Inter"), nil), ("title", "Weight", "700", nil),
            ("h1", "Font", font("Inter"), nil), ("h2", "Font", font("Inter"), nil), ("h3", "Font", font("Inter"), nil),
            ("links", "Colour", "#0f766e", "#2dd4bf"), ("links", "Underline colour", "#5eead4", "#0f766e"),
            ("links", "Hover colour", "#14b8a6", "#5eead4"),
            ("site", "Accent", "#0d9488", "#2dd4bf"), ("site", "Current page", "#0f766e", "#2dd4bf"),
            ("codeblocks", "Line colour", "#14b8a6", "#0f766e"), ("codeblocks", "Corners", "6px", nil),
            ("admonitions", "Corners", "8px", nil), ("admonitions", "Shadow", "none", nil),
        ]),
        make("Elegant", [
            ("text", "Font", font("EB Garamond"), nil), ("text", "Size", "20px", nil), ("text", "Line height", "1.6", nil),
            ("title", "Font", font("EB Garamond"), nil), ("title", "Weight", "400", nil), ("title", "Letters", "small-caps", nil),
            ("title", "Alignment", "center", nil),
            ("h1", "Font", font("EB Garamond"), nil), ("h1", "Weight", "400", nil), ("h1", "Letters", "small-caps", nil),
            ("h2", "Font", font("EB Garamond"), nil), ("h2", "Weight", "400", nil), ("h2", "Letters", "small-caps", nil),
            ("h3", "Font", font("EB Garamond"), nil), ("h3", "Weight", "400", nil), ("h3", "Style", "italic", nil),
            ("links", "Colour", "#9f1239", "#fda4af"), ("links", "Underline colour", "#fecdd3", "#9f1239"),
            ("captions", "Style", "italic", nil), ("captions", "Alignment", "center", nil),
        ]),
        make("Compact", [
            ("text", "Size", "15px", nil), ("text", "Line height", "1.45", nil),
            ("h1", "Size", "1.8em", nil), ("h2", "Size", "1.3em", nil), ("h2", "Space above", "1.4em", nil),
            ("h3", "Size", "1.1em", nil), ("h3", "Space above", "1.2em", nil),
            ("codeblocks", "Size", "12.5px", nil),
            ("admonitions", "Shadow", "none", nil), ("admonitions", "Text size", "0.95em", nil),
        ]),
    ]
}

// MARK: - Library and book

/// Styles for all books: stylesheets in `~/Library/Application Support/JupyterBookNook/Styles`.
public enum StyleLibrary {
    public static var folder: URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["NOOK_STYLE_LIBRARY"] { return URL(fileURLWithPath: path, isDirectory: true) }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("JupyterBookNook/Styles", isDirectory: true)
    }

    /// The user's styles, by name (the file name without .css).
    public static func styles(in folder: URL = folder) -> [(name: String, url: URL)] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension.lowercased() == "css" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { ($0.deletingPathExtension().lastPathComponent, $0) }
    }

    public static func load(_ url: URL) throws -> BookStyle {
        var style = BookStyle(css: try String(contentsOf: url, encoding: .utf8))
        if style.name.isEmpty { style.name = url.deletingPathExtension().lastPathComponent }
        return style
    }

    /// Saves `style` under `name`, replacing a style of that name.
    @discardableResult
    public static func save(_ style: BookStyle, named name: String, in folder: URL = folder) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var named = style
        named.name = name
        let file = folder.appendingPathComponent(TemplateLibrary.fileName(for: name)).appendingPathExtension("css")
        try named.libraryCSS.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    public static func delete(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

extension BookProject {
    /// CSS files in the book (not in _build, node_modules or hidden folders), by path.
    public var cssFiles: [String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var found: [String] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name == "_build" || name == "node_modules" {
                enumerator.skipDescendants()
                continue
            }
            if url.pathExtension.lowercased() == "css", let path = relativePath(of: url) { found.append(path) }
        }
        return found.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The book's style, read from its stylesheet (empty when it has none).
    public var style: BookStyle {
        guard let path = stylesheet, let css = try? String(contentsOf: url(for: path), encoding: .utf8) else { return BookStyle() }
        return BookStyle(css: css)
    }

    /// Writes `style` to the stylesheet as one undoable change. A book without one gets
    /// `styles.css`, listed in `site.options.style`.
    @discardableResult
    public mutating func setStyle(_ style: BookStyle, summary: String = "Style changed") throws -> StructuralChange? {
        let path = stylesheet ?? DarkFigures.defaultStylesheet
        let file = url(for: path)
        let css = style.css
        var operations: [FileOperation] = []
        if let existing = try? String(contentsOf: file, encoding: .utf8) {
            guard existing != css else { return nil }
            operations.append(.edited(file, before: existing, after: css))
        } else {
            operations.append(.created(file, contents: css))
        }
        let listed = stylesheet != nil
        return try commit(toc: nil, operations: operations, summary: summary + (listed ? " — \(path)" : " — \(path) created, myst.yml updated"),
                          config: listed ? nil : { try Self.settingStyle(path, in: $0) })
    }

    /// A text or flag setting of myst.yml at `path`, if set.
    public func configValue(_ path: [String]) -> String? {
        YAMLEditor.value(at: path, in: configText)?.string
    }

    /// Sets (or with nil removes) a myst.yml value as one undoable change.
    @discardableResult
    public mutating func setConfigValue(_ path: [String], to value: YAMLValue?, summary: String) throws -> StructuralChange? {
        let after = try YAMLEditor.setting(path, to: value, in: configText)
        guard after != configText else { return nil }
        return try commit(toc: nil, summary: summary + " — myst.yml updated") { _ in after }
    }

    /// Makes another CSS file of the book the site's stylesheet.
    @discardableResult
    public mutating func useStylesheet(_ path: String) throws -> StructuralChange? {
        guard path != stylesheet else { return nil }
        return try commit(toc: nil, summary: "The site now uses \(path) — myst.yml updated") { try Self.settingStyle(path, in: $0) }
    }
}
