import Foundation

/// The settings of `myst.yml` that the Project Settings forms edit.
///
/// Read from the file, edited in the form, then written back with `changes(from:)`: only the keys
/// whose value changed are rewritten, each as a minimal text edit (see `YAMLEditor`). Keys the
/// form does not know stay as they are.
public struct ProjectSettings: Equatable {
    public struct Author: Equatable, Identifiable {
        public var id = UUID()
        public var name = ""
        public var orcid = ""
        public var email = ""
        public var affiliation = ""
        /// Keys the form does not show (e.g. `corresponding`, `roles`); written back unchanged.
        public var other: [YAMLPair] = []

        public init(name: String = "") { self.name = name }

        public static func == (a: Author, b: Author) -> Bool { a.value == b.value }

        var value: YAMLValue {
            var pairs = [YAMLPair("name", .string(name))]
            if !orcid.isEmpty { pairs.append(YAMLPair("orcid", .string(orcid))) }
            if !email.isEmpty { pairs.append(YAMLPair("email", .string(email))) }
            if !affiliation.isEmpty { pairs.append(YAMLPair("affiliations", .list([.string(affiliation)]))) }
            pairs += other
            return pairs.count == 1 ? .string(name) : .map(pairs)
        }
    }

    public struct Macro: Equatable, Identifiable {
        public var id = UUID()
        public var name: String
        public var expansion: String

        public init(name: String, expansion: String) {
            self.name = name
            self.expansion = expansion
        }

        public static func == (a: Macro, b: Macro) -> Bool { a.name == b.name && a.expansion == b.expansion }
    }

    /// An entry of `project.exports`: a PDF, Word or other document built from the book.
    public struct Export: Equatable, Identifiable {
        public var id = UUID()
        public var format = "pdf"
        public var output = ""
        public var template = ""
        public var other: [YAMLPair] = []

        public init(format: String = "pdf", output: String = "") {
            self.format = format
            self.output = output
        }

        public static func == (a: Export, b: Export) -> Bool { a.value == b.value }

        var value: YAMLValue {
            var pairs = [YAMLPair("format", .string(format))]
            if !template.isEmpty { pairs.append(YAMLPair("template", .string(template))) }
            if !output.isEmpty { pairs.append(YAMLPair("output", .string(output))) }
            return .map(pairs + other)
        }

        /// The `myst build` flag for this format.
        public var buildFlag: String {
            switch format {
            case "pdf", "pdf+tex": return "--pdf"
            case "tex": return "--tex"
            case "typst": return "--typst"
            case "docx": return "--docx"
            case "md": return "--md"
            case "xml", "jats": return "--jats"
            default: return "--" + format
            }
        }
    }

    // MARK: project

    public var title = ""
    public var subtitle = ""
    public var description = ""
    public var authors: [Author] = []
    public var license = ""
    /// `license` is written as a mapping (content and code licences); the form leaves it alone.
    public var licenseIsStructured = false
    public var github = ""
    public var bibliography: [String] = []
    public var keywords: [String] = []
    public var math: [Macro] = []
    public var exports: [Export] = []

    public var numberingEnabled = true
    public var numberHeadings = false
    public var numberFigures = true
    public var numberEquations = true
    public var numberTables = true
    public var numberCode = true
    /// Other keys of `numbering` (`enumerator`, `title`, per-level settings), kept as they are.
    public var numberingOther: [YAMLPair] = []

    /// `project.settings.output_stderr` and `output_stdout`; empty means MyST's default.
    public var outputStderr = ""
    public var outputStdout = ""

    // MARK: site

    public var template = ""
    public var logo = ""
    public var logoDark = ""
    public var logoText = ""
    public var favicon = ""
    /// `site.options.style`: a CSS file added to every page of the site.
    public var style = ""
    public var hideTOC = false
    public var hideOutline = false
    public var hideFooterLinks = false
    public var hideSearch = false
    public var hideAuthors = false
    public var folders = false

    public static let licenses = ["CC-BY-4.0", "CC-BY-SA-4.0", "CC-BY-NC-4.0", "CC-BY-NC-SA-4.0", "CC0-1.0", "MIT", "Apache-2.0", "BSD-3-Clause", "GPL-3.0-or-later"]
    public static let templates = ["book-theme", "article-theme"]
    /// Choices for `output_stderr` and `output_stdout`.
    /// Document formats MyST can export (`project.exports[].format`).
    public static let exportFormats = ["pdf", "typst", "docx", "tex", "md"]
    public static let outputChoices = ["show", "remove", "remove-warn", "remove-error", "warn", "error"]

    public init() {}

    public init(yaml: String) {
        let root = YAMLEditor.value(at: [], in: yaml)
        let project = root?["project"]
        let site = root?["site"]
        func text(_ value: YAMLValue?) -> String { value?.string ?? "" }

        title = text(project?["title"])
        subtitle = text(project?["subtitle"])
        description = text(project?["description"])
        github = text(project?["github"])
        if case .map = project?["license"] {
            licenseIsStructured = true
        } else {
            license = text(project?["license"])
        }
        authors = Self.readAuthors(project?["authors"] ?? project?["author"])
        bibliography = Self.readList(project?["bibliography"])
        keywords = Self.readList(project?["keywords"])
        math = (project?["math"]?.pairs ?? []).map { Macro(name: $0.key, expansion: $0.value.string ?? "") }
        readNumbering(project?["numbering"])
        exports = Self.readExports(project?["exports"] ?? project?["export"])
        outputStderr = text(project?["settings"]?["output_stderr"])
        outputStdout = text(project?["settings"]?["output_stdout"])

        template = text(site?["template"])
        let options = site?["options"]
        logo = text(options?["logo"])
        logoDark = text(options?["logo_dark"])
        logoText = text(options?["logo_text"])
        favicon = text(options?["favicon"])
        style = text(options?["style"])
        func flag(_ key: String) -> Bool { options?[key]?.string?.lowercased() == "true" }
        hideTOC = flag("hide_toc")
        hideOutline = flag("hide_outline")
        hideFooterLinks = flag("hide_footer_links")
        hideSearch = flag("hide_search")
        hideAuthors = flag("hide_authors")
        folders = flag("folders")
    }

    private static func readList(_ value: YAMLValue?) -> [String] {
        switch value {
        case .list(let items): return items.compactMap(\.string)
        case .string(let s), .plain(let s): return s.isEmpty ? [] : [s]
        default: return []
        }
    }

    private static func readExports(_ value: YAMLValue?) -> [Export] {
        guard case .list(let items) = value else { return [] }
        return items.map { item in
            var export = Export(format: item.string ?? "pdf")
            for pair in item.pairs ?? [] {
                switch pair.key {
                case "format": export.format = pair.value.string ?? "pdf"
                case "output": export.output = pair.value.string ?? ""
                case "template": export.template = pair.value.string ?? ""
                default: export.other.append(pair)
                }
            }
            return export
        }
    }

    private static func readAuthors(_ value: YAMLValue?) -> [Author] {
        let items: [YAMLValue]
        switch value {
        case .list(let list): items = list
        case .some(let single): items = [single]
        case nil: items = []
        }
        return items.map { item in
            if let name = item.string { return Author(name: name) }
            var author = Author()
            for pair in item.pairs ?? [] {
                switch pair.key {
                case "name": author.name = pair.value.string ?? ""
                case "orcid": author.orcid = pair.value.string ?? ""
                case "email": author.email = pair.value.string ?? ""
                case "affiliations", "affiliation":
                    if let one = pair.value.string {
                        author.affiliation = one
                    } else if case .list(let list) = pair.value, list.count == 1, let one = list[0].string {
                        author.affiliation = one
                    } else {
                        author.other.append(pair)
                    }
                default: author.other.append(pair)
                }
            }
            return author
        }
    }

    // MARK: Numbering

    private static let numberingAliases = [
        "sections": "headings", "figures": "figure", "equations": "equation", "math": "equation",
        "tables": "table",
    ]

    private mutating func readNumbering(_ value: YAMLValue?) {
        switch value {
        case .plain(let s)?:
            numberingEnabled = s.lowercased() != "false"
            numberHeadings = s.lowercased() == "true"
        case .map(let pairs)?:
            for pair in pairs {
                let key = Self.numberingAliases[pair.key] ?? pair.key
                // `figure: false` or `figure: {enabled: false}`; anything richer is kept as is.
                let enabled: Bool? = pair.value.string.map { $0.lowercased() == "true" }
                    ?? (pair.value.pairs?.count == 1 ? pair.value["enabled"]?.string.map { $0.lowercased() == "true" } : nil)
                switch (key, enabled) {
                case ("headings", let e?): numberHeadings = e
                case ("figure", let e?): numberFigures = e
                case ("equation", let e?): numberEquations = e
                case ("table", let e?): numberTables = e
                case ("code", let e?): numberCode = e
                default: numberingOther.append(pair)
                }
            }
        default: break
        }
    }

    private var numberingValue: YAMLValue? {
        guard numberingEnabled else { return .bool(false) }
        var pairs = numberingOther
        if numberHeadings { pairs.append(YAMLPair("headings", .bool(true))) }
        if !numberFigures { pairs.append(YAMLPair("figure", .bool(false))) }
        if !numberEquations { pairs.append(YAMLPair("equation", .bool(false))) }
        if !numberTables { pairs.append(YAMLPair("table", .bool(false))) }
        if !numberCode { pairs.append(YAMLPair("code", .bool(false))) }
        return pairs.isEmpty ? nil : .map(pairs)
    }

    // MARK: Writing

    /// Every key the form writes, with its value (nil: the key is removed).
    private var entries: [(path: [String], value: YAMLValue?)] {
        func text(_ s: String) -> YAMLValue? {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .string(trimmed)
        }
        func list(_ items: [String]) -> YAMLValue? {
            let kept = items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return kept.isEmpty ? nil : .list(kept.map(YAMLValue.string))
        }
        func flag(_ b: Bool) -> YAMLValue? { b ? .bool(true) : nil }
        let namedAuthors = authors.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        let macros = math.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        var result: [(path: [String], value: YAMLValue?)] = [
            (["project", "title"], text(title)),
            (["project", "subtitle"], text(subtitle)),
            (["project", "description"], text(description)),
            (["project", "authors"], namedAuthors.isEmpty ? nil : .list(namedAuthors.map(\.value))),
            (["project", "github"], text(github)),
            (["project", "bibliography"], list(bibliography)),
            (["project", "keywords"], list(keywords)),
            (["project", "math"], macros.isEmpty ? nil : .map(macros.map { YAMLPair($0.name.trimmingCharacters(in: .whitespaces), .string($0.expansion)) })),
            (["project", "numbering"], numberingValue),
            (["project", "exports"], exports.isEmpty ? nil : .list(exports.map(\.value))),
            (["project", "settings", "output_stderr"], text(outputStderr)),
            (["project", "settings", "output_stdout"], text(outputStdout)),
            (["site", "template"], text(template)),
            (["site", "options", "logo"], text(logo)),
            (["site", "options", "logo_dark"], text(logoDark)),
            (["site", "options", "logo_text"], text(logoText)),
            (["site", "options", "favicon"], text(favicon)),
            (["site", "options", "style"], text(style)),
            (["site", "options", "hide_toc"], flag(hideTOC)),
            (["site", "options", "hide_outline"], flag(hideOutline)),
            (["site", "options", "hide_footer_links"], flag(hideFooterLinks)),
            (["site", "options", "hide_search"], flag(hideSearch)),
            (["site", "options", "hide_authors"], flag(hideAuthors)),
            (["site", "options", "folders"], flag(folders)),
        ]
        if !licenseIsStructured { result.append((["project", "license"], text(license))) }
        return result
    }

    /// The keys whose value differs from `old`, as (path, new value or nil to remove).
    public func changes(from old: ProjectSettings) -> [(path: [String], value: YAMLValue?)] {
        let before = Dictionary(old.entries.map { ($0.path.joined(separator: "."), $0.value) }, uniquingKeysWith: { a, _ in a })
        return entries.filter { before[$0.path.joined(separator: ".")] != $0.value }
    }

    /// `yaml` with the changes from `old` written into it.
    public func applying(to yaml: String, from old: ProjectSettings) throws -> String {
        var text = yaml
        for change in changes(from: old) {
            // An `author:` alias is replaced by `authors:`.
            if change.path == ["project", "authors"] {
                text = try YAMLEditor.setting(["project", "author"], to: nil, in: text)
            }
            if change.path == ["project", "exports"] {
                text = try YAMLEditor.setting(["project", "export"], to: nil, in: text)
            }
            text = try YAMLEditor.setting(change.path, to: change.value, in: text)
        }
        return text
    }
}
