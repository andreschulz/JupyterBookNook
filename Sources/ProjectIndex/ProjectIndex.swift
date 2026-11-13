import Foundation
import MystSyntax

/// What the whole book defines: labels in every page, citation keys and files. Built once when a
/// book opens, then updated page by page; the open page is indexed from the editor's text.
public struct ProjectIndex: Sendable {
    public struct LabelEntry: Equatable, Sendable {
        public var label: PageSymbols.Label
        public var page: String
    }

    public private(set) var pages: [String: PageSymbols] = [:]
    public private(set) var citations: [String: BibEntry] = [:]
    /// Every file in the project (relative paths), for path completion and missing-file checks.
    public private(set) var files: Set<String> = []
    /// True when the book configures a bibliography or has .bib files, so unknown keys are reported.
    public private(set) var hasBibliography = false
    /// Directives and roles added by the book's plugins: completed, and not reported as unknown.
    public var pluginDirectives: [MystCatalog.Entry] = []
    public var pluginRoles: [MystCatalog.Entry] = []
    /// True while a plugin of the book could not be read: it may add any name, so unknown
    /// directives and roles are not reported.
    public var hasUnreadPlugins = false

    public init() {}

    static let skippedFolders: Set<String> = ["_build", "node_modules", "__pycache__", ".git"]

    /// Reads every Markdown page and bibliography of the book in `root`.
    /// `bibliography` lists the .bib files from `myst.yml`; when empty, all .bib files are used.
    public static func build(root: URL, bibliography: [String]) -> ProjectIndex {
        var index = ProjectIndex()
        index.files = Self.allFiles(in: root)
        for file in index.files where file.hasSuffix(".md") {
            if let text = try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8) {
                index.pages[file] = PageSymbols.scan(text)
            }
        }
        let bibFiles = bibliography.isEmpty ? index.files.filter { $0.hasSuffix(".bib") }.sorted() : bibliography
        index.hasBibliography = !bibFiles.isEmpty
        for file in bibFiles {
            guard let text = try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8) else { continue }
            for entry in BibTeX.entries(in: text, file: file) where index.citations[entry.key] == nil {
                index.citations[entry.key] = entry
            }
        }
        return index
    }

    /// Re-indexes one page from its current text.
    public mutating func update(page: String, text: String) {
        pages[page] = PageSymbols.scan(text)
        files.insert(page)
    }

    public mutating func remove(page: String) {
        pages[page] = nil
        files.remove(page)
    }

    /// All labels in the book, in page order then document order.
    public var labels: [LabelEntry] {
        pages.keys.sorted().flatMap { page in pages[page]!.labels.map { LabelEntry(label: $0, page: page) } }
    }

    /// MyST's directives followed by the plugins'.
    public var directives: [MystCatalog.Entry] { MystCatalog.directives + pluginDirectives }
    public var roles: [MystCatalog.Entry] { MystCatalog.roles + pluginRoles }

    public func directive(_ name: String) -> MystCatalog.Entry? {
        MystCatalog.directive(name) ?? pluginDirectives.first { $0.name == name }
    }

    public func role(_ name: String) -> MystCatalog.Entry? {
        MystCatalog.role(name) ?? pluginRoles.first { $0.name == name }
    }

    public func definitions(of name: String) -> [LabelEntry] {
        labels.filter { $0.label.name == name }
    }

    static func allFiles(in root: URL) -> Set<String> {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var files = Set<String>()
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if skippedFolders.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            if path.hasPrefix(base) { files.insert(String(path.dropFirst(base.count))) }
        }
        return files
    }
}

/// Paths relative to a page, as MyST resolves them.
enum PagePath {
    static func resolve(_ path: String, from page: String) -> String? {
        let base: [String] = path.hasPrefix("/") ? [] : page.split(separator: "/").dropLast().map(String.init)
        var stack: [String] = []
        for part in base + path.split(separator: "/").map(String.init) where part != "." && !part.isEmpty {
            if part == ".." {
                guard !stack.isEmpty else { return nil }
                stack.removeLast()
            } else {
                stack.append(part)
            }
        }
        return stack.isEmpty ? nil : stack.joined(separator: "/")
    }

    /// `path` written relative to the folder of `page`.
    static func relative(_ path: String, from page: String) -> String {
        let from = page.split(separator: "/").dropLast().map(String.init)
        let to = path.split(separator: "/").map(String.init)
        var common = 0
        while common < from.count, common < to.count - 1, from[common] == to[common] { common += 1 }
        return (Array(repeating: "..", count: from.count - common) + to[common...]).joined(separator: "/")
    }
}
