import Foundation
import MystSyntax

/// One completion suggestion: the text inserted for the partial name, and what the list shows.
public struct CompletionItem: Equatable, Sendable {
    /// What a suggestion is, for its icon.
    public enum Kind: String, Sendable {
        case section, equation, figure, table, code, theorem, page, directive, role, citation, file, option
    }

    /// Replaces the partial name.
    public var insert: String
    /// Typed after `insert` when the suggestion is chosen (e.g. "}" after a directive name).
    public var suffix: String
    /// Moves the cursor back this far after inserting, e.g. into the backticks of a role.
    public var cursorBack: Int
    public var title: String
    /// Short text at the right of the row, e.g. the page a label is on.
    public var trailing: String?
    /// For the area under the list: a bold title and a description or snippet.
    public var previewTitle: String?
    public var detail: String?
    public var kind: Kind

    public init(insert: String, suffix: String = "", cursorBack: Int = 0, title: String, trailing: String? = nil,
                previewTitle: String? = nil, detail: String? = nil, kind: Kind) {
        self.insert = insert
        self.suffix = suffix
        self.cursorBack = cursorBack
        self.title = title
        self.trailing = trailing
        self.previewTitle = previewTitle
        self.detail = detail
        self.kind = kind
    }
}

extension ProjectIndex {
    /// Suggestions for `context` while editing `page`, best matches first.
    public func completions(for context: CompletionContext, page: String, textAfterCursor: String = "") -> [CompletionItem] {
        let next = textAfterCursor.first
        var items: [CompletionItem]
        switch context.kind {
        case .directiveName:
            items = directives.map {
                CompletionItem(insert: $0.name, suffix: next == "}" ? "" : "}", title: $0.name,
                               previewTitle: "{\($0.name)}", detail: $0.summary, kind: .directive)
            }
        case .roleName:
            items = roles.map {
                CompletionItem(insert: $0.name, suffix: next == "}" ? "" : "}``", cursorBack: next == "}" ? 0 : 1, title: $0.name,
                               previewTitle: "{\($0.name)}", detail: $0.summary, kind: .role)
            }
        case .label(let role):
            let kinds = MystCatalog.labelRoles[role] ?? nil
            items = labels.filter { kinds?.contains($0.label.kind) ?? true }.map { labelItem($0, page: page) }
        case .linkAnchor:
            let own = (pages[page]?.headingAnchors ?? []).map {
                CompletionItem(insert: $0, title: $0, trailing: "this page", previewTitle: "Heading on this page", kind: .section)
            }
            items = own + labels.map { labelItem($0, page: page) }
        case .citation:
            items = citations.values.sorted { $0.key < $1.key }.map { entry in
                let author = entry.authors?.components(separatedBy: " and ").first?.components(separatedBy: ",").first?
                    .trimmingCharacters(in: .whitespaces)
                return CompletionItem(insert: entry.key, title: entry.key, trailing: entry.year,
                                      previewTitle: [author, entry.year].compactMap { $0 }.joined(separator: " "),
                                      detail: entry.title, kind: .citation)
            }
        case .path(let via):
            let wanted: (String) -> Bool
            switch via {
            case "figure", "image": wanted = { ["png", "jpg", "jpeg", "gif", "svg", "webp", "pdf"].contains(($0 as NSString).pathExtension.lowercased()) }
            case "include": wanted = { ["md", "txt", "tex"].contains(($0 as NSString).pathExtension.lowercased()) }
            case "doc": wanted = { $0.hasSuffix(".md") || $0.hasSuffix(".ipynb") }
            default: wanted = { _ in true }
            }
            items = files.filter { $0 != page && wanted($0) }.sorted().map { file in
                var written = PagePath.relative(file, from: page)
                if via == "doc" { written = (written as NSString).deletingPathExtension }
                return CompletionItem(insert: written, title: written, kind: .file)
            }
        case .directiveOption(let directive, let used):
            let options = self.directive(directive)?.options ?? ["label", "class"]
            items = options.filter { !used.contains($0) }.map {
                CompletionItem(insert: $0, suffix: ": ", title: $0, previewTitle: ":\($0):", detail: "Option of {\(directive)}", kind: .option)
            }
        }
        return Self.rank(items, prefix: context.prefix)
    }

    /// A label as a suggestion: its page at the right, and its title and snippet below the list.
    func labelItem(_ entry: LabelEntry, page: String) -> CompletionItem {
        let kind: CompletionItem.Kind
        switch entry.label.kind {
        case .equation: kind = .equation
        case .figure: kind = .figure
        case .table: kind = .table
        case .code: kind = .code
        case .theorem, .exercise: kind = .theorem
        case .page: kind = .page
        case .heading, .target, .other: kind = .section
        }
        let trailing = entry.page == page ? "this page" : (entry.page as NSString).lastPathComponent
        let title = entry.label.title ?? entry.label.kind.rawValue.capitalized
        return CompletionItem(insert: entry.label.name, title: entry.label.name, trailing: trailing,
                              previewTitle: title, detail: entry.label.snippet.map { "“\($0)”" }, kind: kind)
    }

    /// Items starting with the prefix first, then those containing it; case-insensitive.
    static func rank(_ items: [CompletionItem], prefix: String) -> [CompletionItem] {
        guard !prefix.isEmpty else { return items }
        let needle = prefix.lowercased()
        let starting = items.filter { $0.title.lowercased().hasPrefix(needle) }
        let containing = items.filter { !$0.title.lowercased().hasPrefix(needle) && $0.title.lowercased().contains(needle) }
        return starting + containing
    }
}
