import Foundation

/// Values put into a template's placeholders: `{{title}}`, `{{label}}`, `{{author}}`, `{{date}}`, `{{book}}`.
public struct TemplateValues {
    public var title: String
    public var author: String
    public var book: String
    public var date: Date

    public init(title: String, author: String = "", book: String = "", date: Date = Date()) {
        self.title = title
        self.author = author
        self.book = book
        self.date = date
    }

    /// A label-friendly form of the title: `Gradient Descent` → `gradient-descent`.
    public var label: String { BookProject.slug(for: title) }

    /// Fills the placeholders. In YAML files the values are quoted where needed, so a title
    /// like `Notes: draft` stays valid.
    func fill(_ text: String, yaml: Bool = false) -> String {
        func value(_ s: String) -> String { yaml ? YAMLEditor.scalar(s) : s }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return text
            .replacingOccurrences(of: "{{title}}", with: value(title))
            .replacingOccurrences(of: "{{label}}", with: label)
            .replacingOccurrences(of: "{{author}}", with: value(author.isEmpty ? "Author" : author))
            .replacingOccurrences(of: "{{book}}", with: value(book))
            .replacingOccurrences(of: "{{date}}", with: formatter.string(from: date))
    }
}

/// A template: a whole new page, or a snippet inserted while typing (⌘T).
public struct PageTemplate: Identifiable, Equatable {
    public enum Source: String {
        case builtIn = "Built in"
        case user = "Your templates"
        case project = "This book"
    }

    public enum Kind: String, CaseIterable {
        case snippet = "Snippets"
        case page = "Page templates"
    }

    public var name: String
    public var summary: String
    public var body: String
    public var source: Source
    public var kind: Kind
    /// The template's file, for user and project templates.
    public var url: URL?
    /// A user or book template that replaces the built-in one of the same name.
    public var overridesBuiltIn = false

    public var id: String { kind.rawValue + "/" + name }

    public init(name: String, summary: String, body: String, source: Source = .builtIn, kind: Kind = .page, url: URL? = nil) {
        self.name = name
        self.summary = summary
        self.body = body
        self.source = source
        self.kind = kind
        self.url = url
    }

    public func render(_ values: TemplateValues) -> String { values.fill(body) }

    /// The text a snippet inserts and the range to select afterwards. `{{selection}}` becomes the
    /// selected text; `{{cursor}}` marks where the cursor goes, `{{cursor:text}}` inserts `text` selected.
    /// Without a marker the cursor goes to the end.
    public func insertion(selection: String, values: TemplateValues) -> (text: String, selection: NSRange) {
        let result = snippetInsertion(selection: selection, values: values)
        return (result.text, result.stops[0])
    }

    /// A snippet ready to insert: its text and its tab stops (UTF-16 ranges in `text`). The first
    /// stop is selected after inserting; ⇥ moves to the next.
    public struct Insertion: Equatable {
        public var text: String
        public var stops: [NSRange]
    }

    /// Like `insertion`, with tab stops: `{{cursor}}` / `{{cursor:text}}` is the first stop,
    /// `{{2:text}}`, `{{3}}`, … follow in number order. Without `{{cursor}}`, the first numbered
    /// stop is where the cursor goes; without any, the end.
    public func snippetInsertion(selection: String, values: TemplateValues) -> Insertion {
        let filled = values.fill(body).replacingOccurrences(of: "{{selection}}", with: selection)
        var text = ""
        var marked: [(order: Int, range: NSRange)] = []
        var rest = Substring(filled)
        var length = 0
        var seenCursor = false
        while let open = rest.range(of: "{{") {
            let before = rest[..<open.lowerBound]
            text += before
            length += (String(before) as NSString).length
            guard let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) else {
                rest = rest[open.lowerBound...]
                break
            }
            let inner = String(rest[open.upperBound..<close.lowerBound])
            let name = inner.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
            let order: Int? = name == "cursor" ? 1 : Int(name).flatMap { (1...99).contains($0) ? $0 : nil }
            if let order {
                let placeholder = inner.contains(":") ? String(inner[inner.index(after: inner.firstIndex(of: ":")!)...]) : ""
                let placeholderLength = (placeholder as NSString).length
                // Only the first `{{cursor}}` is a stop; later ones (nested snippets) just disappear.
                if name != "cursor" || !seenCursor {
                    marked.append((order, NSRange(location: length, length: placeholderLength)))
                }
                if name == "cursor" { seenCursor = true }
                text += placeholder
                length += placeholderLength
            } else {
                // Not a stop: keep it as written.
                let kept = String(rest[open.lowerBound..<close.upperBound])
                text += kept
                length += (kept as NSString).length
            }
            rest = rest[close.upperBound...]
        }
        text += rest
        let stops = marked.enumerated().sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }.map(\.element.range)
        return Insertion(text: text, stops: stops.isEmpty ? [NSRange(location: (text as NSString).length, length: 0)] : stops)
    }

    /// The file contents for this template: the summary as a first-line comment, then the body.
    public var fileContents: String {
        (summary.isEmpty ? "" : "<!-- \(summary) -->\n") + body
    }

    /// Reads a template file. The name is the file name; an optional first line
    /// `<!-- description -->` gives the summary and is not part of the page.
    public init?(fileAt url: URL, source: Source, kind: Kind = .page) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var body = text
        var summary = ""
        if text.hasPrefix("<!--"), let end = text.range(of: "-->") {
            summary = text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            body = String(String(text[end.upperBound...]).trimmingPrefix(while: \.isNewline))
        }
        self.init(name: url.deletingPathExtension().lastPathComponent, summary: summary, body: body, source: source, kind: kind, url: url)
    }
}

/// A starting point for a new book: `myst.yml` and its first pages.
public struct ProjectTemplate: Identifiable, Equatable {
    public var name: String
    public var summary: String
    /// Relative path → contents, with placeholders.
    public var files: [(path: String, contents: String)]
    public var symbol: String
    /// A folder of the user's own book template, copied as is (text files get their placeholders filled).
    public var folder: URL?

    public var id: String { name }

    public static func == (a: ProjectTemplate, b: ProjectTemplate) -> Bool { a.name == b.name && a.folder == b.folder }
}

/// Built-in templates plus the user's own (plain files in Application Support) and the book's
/// (in `.nook/templates/`).
public enum TemplateLibrary {
    /// `~/Library/Application Support/JupyterBookNook/Templates`.
    public static var userFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("JupyterBookNook/Templates", isDirectory: true)
    }

    public static var userPagesFolder: URL { userFolder.appendingPathComponent("Pages", isDirectory: true) }
    public static var userSnippetsFolder: URL { userFolder.appendingPathComponent("Snippets", isDirectory: true) }
    public static var userBooksFolder: URL { userFolder.appendingPathComponent("Books", isDirectory: true) }

    public static func projectFolder(of root: URL) -> URL {
        root.appendingPathComponent(".nook/templates", isDirectory: true)
    }

    /// Where templates of `kind` from `source` are stored (nil for built-in ones).
    public static func folder(for kind: PageTemplate.Kind, source: PageTemplate.Source, projectRoot: URL?, userFolder: URL = userFolder) -> URL? {
        switch (source, kind) {
        case (.builtIn, _): return nil
        case (.user, .page): return userFolder.appendingPathComponent("Pages", isDirectory: true)
        case (.user, .snippet): return userFolder.appendingPathComponent("Snippets", isDirectory: true)
        case (.project, .page): return projectRoot.map(projectFolder(of:))
        case (.project, .snippet): return projectRoot.map { projectFolder(of: $0).appendingPathComponent("snippets", isDirectory: true) }
        }
    }

    /// Templates of `kind`: built in, then the user's, then the book's. A user or book template with
    /// the name of a built-in one replaces it (the book's wins over the user's).
    public static func templates(_ kind: PageTemplate.Kind, projectRoot: URL?, userFolder: URL = userFolder) -> [PageTemplate] {
        var result = kind == .page ? builtInPages : builtInSnippets
        for source in [PageTemplate.Source.user, .project] {
            guard let folder = folder(for: kind, source: source, projectRoot: projectRoot, userFolder: userFolder) else { continue }
            for url in markdownFiles(in: folder) {
                guard var template = PageTemplate(fileAt: url, source: source, kind: kind) else { continue }
                if let index = result.firstIndex(where: { $0.name == template.name }) {
                    template.overridesBuiltIn = result[index].source == .builtIn || result[index].overridesBuiltIn
                    result[index] = template
                } else {
                    result.append(template)
                }
            }
        }
        return result
    }

    /// Templates kept inside a book (`.nook/templates`), from before templates were the same for
    /// every book. The app no longer offers them; they can be moved to the user's templates.
    public static func bookTemplates(projectRoot: URL, userFolder: URL = userFolder) -> [PageTemplate] {
        PageTemplate.Kind.allCases.flatMap { kind in
            folder(for: kind, source: .project, projectRoot: projectRoot, userFolder: userFolder).map { folder in
                markdownFiles(in: folder).compactMap { PageTemplate(fileAt: $0, source: .project, kind: kind) }
            } ?? []
        }
    }

    /// Moves a book's own templates into the user's templates (for all books). A name the user
    /// already has gets " (bookname)" appended. Returns how many were moved.
    @discardableResult
    public static func moveBookTemplatesToUser(projectRoot: URL, bookName: String, userFolder: URL = userFolder) throws -> Int {
        let book = bookTemplates(projectRoot: projectRoot, userFolder: userFolder)
        for template in book {
            var moved = template
            moved.source = .user
            let taken = Set(templates(template.kind, projectRoot: nil, userFolder: userFolder).filter { $0.source == .user }.map(\.name))
            if taken.contains(moved.name) { moved.name += " (\(bookName))" }
            try save(moved, replacing: template, projectRoot: nil, userFolder: userFolder)
        }
        // Remove the emptied folders.
        let fm = FileManager.default
        let folder = projectFolder(of: projectRoot)
        for sub in [folder.appendingPathComponent("snippets"), folder, folder.deletingLastPathComponent()] {
            if (try? fm.contentsOfDirectory(atPath: sub.path))?.isEmpty == true { try? fm.removeItem(at: sub) }
        }
        return book.count
    }

    public static func pageTemplates(projectRoot: URL?, userFolder: URL = userFolder) -> [PageTemplate] {
        templates(.page, projectRoot: projectRoot, userFolder: userFolder)
    }

    public static func builtIn(named name: String, kind: PageTemplate.Kind) -> PageTemplate? {
        (kind == .page ? builtInPages : builtInSnippets).first { $0.name == name }
    }

    /// Writes `template` to its source's folder and returns it with its file. When it replaces
    /// `previous` under another name or place, the previous file is removed.
    @discardableResult
    public static func save(_ template: PageTemplate, replacing previous: PageTemplate?, projectRoot: URL?, userFolder: URL = userFolder) throws -> PageTemplate {
        guard let folder = folder(for: template.kind, source: template.source, projectRoot: projectRoot, userFolder: userFolder) else {
            return template
        }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName(for: template.name)).appendingPathExtension("md")
        try template.fileContents.write(to: url, atomically: true, encoding: .utf8)
        if let old = previous?.url, old.standardizedFileURL != url.standardizedFileURL {
            try? fm.removeItem(at: old)
        }
        var saved = template
        saved.url = url
        return saved
    }

    /// Moves a user or book template's file to the Trash (or deletes it where there is no Trash).
    public static func delete(_ template: PageTemplate) throws {
        guard let url = template.url else { return }
        #if os(macOS)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        #else
        try FileManager.default.removeItem(at: url)
        #endif
    }

    /// A file name for a template name: no slashes or colons.
    public static func fileName(for name: String) -> String {
        let cleaned = name.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    public static func projectTemplates(userBooks: URL = userBooksFolder) -> [ProjectTemplate] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: userBooks, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let own = folders
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(BookProject.configFileName).path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { ProjectTemplate(name: $0.lastPathComponent, summary: "Your template", files: [], symbol: "folder", folder: $0) }
        return builtInProjects + own
    }

    private static func markdownFiles(in folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files.filter { $0.pathExtension.lowercased() == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Makes `folder` a project and returns it. The folder is created if needed; it may already
    /// hold files, which are never overwritten. Without a `myst.yml` the template's files are added
    /// (the pages of a built-in template in the pages folder); a folder that already is a project
    /// keeps its files. Either way the folders for pages, figures, downloads and plugins are added
    /// where missing (the project's own folders from `.jupyterbooknook.yml`, else the defaults).
    @discardableResult
    public static func createProject(_ template: ProjectTemplate, at folder: URL, values: TemplateValues) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let folders = BookProject.readFolders(in: folder)
        if !fm.fileExists(atPath: folder.appendingPathComponent(BookProject.configFileName).path) {
            if let source = template.folder {
                try copyFilling(from: source, to: folder, values: values)
            } else {
                for file in pages(of: template.files, in: folders.pages) {
                    let url = folder.appendingPathComponent(file.path)
                    guard !fm.fileExists(atPath: url.path) else { continue }
                    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try values.fill(file.contents, yaml: Self.isYAML(url)).write(to: url, atomically: true, encoding: .utf8)
                }
            }
        }
        for path in [folders.pages, folders.figures, folders.downloads, folders.plugins] where !path.isEmpty {
            try fm.createDirectory(at: folder.appendingPathComponent(path, isDirectory: true), withIntermediateDirectories: true)
        }
        return folder
    }

    /// A built-in template's files with its pages moved into `folder`, and myst.yml listing them there.
    static func pages(of files: [(path: String, contents: String)], in folder: String) -> [(path: String, contents: String)] {
        guard !folder.isEmpty else { return files }
        let pages = files.map(\.path).filter { $0.hasSuffix(".md") }
        return files.map { file in
            if file.path.hasSuffix(".md") { return (BookProject.path(in: folder, file.path), file.contents) }
            guard file.path == BookProject.configFileName else { return file }
            var config = file.contents
            for page in pages { config = config.replacingOccurrences(of: "- file: \(page)\n", with: "- file: \(folder)/\(page)\n") }
            return (file.path, config)
        }
    }

    private static func isYAML(_ url: URL) -> Bool { isYAML(url.path) }
    static func isYAML(_ path: String) -> Bool { ["yml", "yaml"].contains((path as NSString).pathExtension.lowercased()) }

    private static let textExtensions: Set<String> = ["md", "yml", "yaml", "bib", "txt", "ipynb", "css", "tex"]

    private static func copyFilling(from source: URL, to destination: URL, values: TemplateValues) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        let base = source.standardizedFileURL.path
        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            let relative = String(path.dropFirst(base.count + 1))
            if relative.hasPrefix("_build") { enumerator.skipDescendants(); continue }
            let target = destination.appendingPathComponent(relative)
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else if fm.fileExists(atPath: target.path) {
                continue // the folder's own files are kept
            } else if textExtensions.contains(url.pathExtension.lowercased()), let text = try? String(contentsOf: url, encoding: .utf8) {
                try values.fill(text, yaml: isYAML(url)).write(to: target, atomically: true, encoding: .utf8)
            } else {
                try fm.copyItem(at: url, to: target)
            }
        }
    }

    // MARK: Built-in page templates

    public static let builtInPages: [PageTemplate] = [
        PageTemplate(name: "Blank page", summary: "A heading, nothing else.", body: "# {{title}}\n\n"),
        PageTemplate(name: "Chapter", summary: "A labelled heading, an introduction and a first section.", body: """
        (sec-{{label}})=
        # {{title}}

        A short introduction: what this chapter is about and what the reader will learn.

        ## First section

        """),
        PageTemplate(name: "Exercise and solution", summary: "An exercise with a hidden solution below it.", body: """
        # {{title}}

        :::{exercise}
        :label: ex-{{label}}

        State the exercise here.
        :::

        :::{solution} ex-{{label}}
        :class: dropdown

        Write the solution here.
        :::

        """),
        PageTemplate(name: "Theorem and proof", summary: "A labelled theorem followed by its proof.", body: """
        # {{title}}

        :::{prf:theorem} Name of the theorem
        :label: thm-{{label}}

        State the theorem here.
        :::

        :::{prf:proof}
        Write the proof here.
        :::

        """),
        PageTemplate(name: "Notebook page", summary: "A Markdown notebook with a Python kernel and a code cell.", body: """
        ---
        kernelspec:
          name: python3
          display_name: Python 3
        ---

        # {{title}}

        ```{code-cell} python
        import numpy as np
        ```

        """),
    ]

    // MARK: Built-in snippets

    public static let builtInSnippets: [PageTemplate] = [
        snippet("Figure", "An image with a caption and a label.", """
        :::{figure} {{cursor:images/figure.png}}
        :label: fig-{{2:name}}
        :width: 80%

        {{3:Caption.}}{{selection}}
        :::
        """),
        snippet("Table", "A table written as a list, with a header row and a label.", """
        :::{list-table} {{cursor:Caption}}
        :header-rows: 1
        :label: tbl-{{2:name}}

        * - {{3:Column 1}}
          - {{4:Column 2}}
        * - {{5:a}}
          - {{6:b}}
        :::
        """),
        snippet("Equation", "A numbered equation with a label.", """
        ```{math}
        :label: eq-{{cursor:name}}

        {{selection}}
        ```
        """),
        snippet("Note", "An admonition box; the selection goes inside.", """
        :::{note}
        {{cursor}}{{selection}}
        :::
        """),
        snippet("Admonition", "A box with your own title and style.", """
        :::{admonition} {{cursor:Title}}
        :class: {{2:tip}}

        {{selection}}
        :::
        """),
        snippet("Dropdown", "Content that opens on click.", """
        :::{dropdown} {{cursor:Title}}
        {{selection}}
        :::
        """),
        snippet("Tabs", "Two tabs side by side.", """
        ::::{tab-set}
        :::{tab-item} {{cursor:First}}
        {{selection}}
        :::
        :::{tab-item} {{2:Second}}
        :::
        ::::
        """),
        snippet("Cards", "A grid with two cards.", """
        ::::{grid} 1 1 2 2
        :::{card} {{cursor:Title}}
        {{2:Text.}}
        :::
        :::{card} {{3:Title}}
        {{4:Text.}}
        :::
        ::::
        """),
        snippet("Theorem and proof", "A labelled theorem followed by its proof.", """
        :::{prf:theorem} {{cursor:Name}}
        :label: thm-{{2:name}}

        {{selection}}
        :::

        :::{prf:proof}
        :::
        """),
        snippet("Exercise and solution", "An exercise with a hidden solution.", """
        :::{exercise}
        :label: {{cursor:ex-name}}

        {{selection}}
        :::

        :::{solution} {{2:ex-name}}
        :class: dropdown

        {{3}}
        :::
        """),
        snippet("Code cell", "Python code that runs when notebooks are executed.", """
        ```{code-cell} python
        {{cursor}}{{selection}}
        ```
        """),
        snippet("Label", "A label above a heading, for {ref}.", "({{cursor:sec-name}})=\n"),
    ]

    private static func snippet(_ name: String, _ summary: String, _ body: String) -> PageTemplate {
        PageTemplate(name: name, summary: summary, body: body + (body.hasSuffix("\n") ? "" : "\n"), kind: .snippet)
    }

    // MARK: Built-in book templates

    private static func config(_ project: String, toc: String, site: String = "  template: book-theme\n  options:\n    style: styles.css") -> String {
        """
        # Created by JupyterBookNook on {{date}}. See https://mystmd.org/guide/frontmatter
        version: 1
        project:
          title: {{book}}
        \(project)
          toc:
        \(toc)
        site:
        \(site)

        """
    }

    public static let builtInProjects: [ProjectTemplate] = [
        ProjectTemplate(
            name: "Blank project",
            summary: "myst.yml and one page.",
            files: [
                ("styles.css", DarkFigures.block),
                ("myst.yml", config("  authors:\n    - {{author}}", toc: "    - file: intro.md")),
                ("intro.md", "# {{book}}\n\nStart writing here.\n"),
            ],
            symbol: "doc"
        ),
        ProjectTemplate(
            name: "Lecture notes",
            summary: "Introduction, two parts with chapters, math macros and a bibliography.",
            files: [
                ("styles.css", DarkFigures.block),
                ("myst.yml", config("""
                  authors:
                    - {{author}}
                  license: CC-BY-4.0
                  bibliography:
                    - references.bib
                  math:
                    '\\R': '\\mathbb{R}'
                  numbering:
                    headings: true
                """, toc: """
                    - file: intro.md
                    - title: Part I · Foundations
                      children:
                        - file: basics.md
                    - title: Part II · Methods
                      children:
                        - file: methods.md
                """)),
                ("intro.md", "# {{book}}\n\nThese notes accompany the lecture. They are written by {{author}}.\n"),
                ("basics.md", """
                (sec-basics)=
                # Basics

                Let $f: \\R^n \\to \\R$ be a differentiable function.

                ```{math}
                :label: eq-example
                \\nabla f(x) = 0
                ```

                Equation {eq}`eq-example` is the first-order condition.

                """),
                ("methods.md", "# Methods\n\nAs shown in {ref}`sec-basics`, …\n"),
                ("references.bib", """
                @book{example2024,
                  title = {An Example Book},
                  author = {Doe, Jane},
                  year = {2024},
                  publisher = {Example Press}
                }

                """),
            ],
            symbol: "graduationcap"
        ),
        ProjectTemplate(
            name: "Thesis",
            summary: "Abstract, the usual chapters, numbered headings and a bibliography.",
            files: [
                ("styles.css", DarkFigures.block),
                ("myst.yml", config("""
                  authors:
                    - {{author}}
                  bibliography:
                    - references.bib
                  numbering:
                    headings: true
                """, toc: """
                    - file: abstract.md
                    - file: introduction.md
                    - file: background.md
                    - file: methods.md
                    - file: results.md
                    - file: conclusion.md
                """)),
                ("abstract.md", "# Abstract\n\nSummarise the question, the approach and the main result.\n"),
                ("introduction.md", "(sec-introduction)=\n# Introduction\n\nMotivation and research question.\n"),
                ("background.md", "(sec-background)=\n# Background\n\nRelated work, e.g. {cite}`example2024`.\n"),
                ("methods.md", "(sec-methods)=\n# Methods\n\n"),
                ("results.md", "(sec-results)=\n# Results\n\n"),
                ("conclusion.md", "(sec-conclusion)=\n# Conclusion\n\n"),
                ("references.bib", """
                @book{example2024,
                  title = {An Example Book},
                  author = {Doe, Jane},
                  year = {2024},
                  publisher = {Example Press}
                }

                """),
            ],
            symbol: "text.book.closed"
        ),
        ProjectTemplate(
            name: "Course with exercises",
            summary: "Weeks with a lecture page and an exercise sheet each.",
            files: [
                ("styles.css", DarkFigures.block),
                ("myst.yml", config("""
                  authors:
                    - {{author}}
                  license: CC-BY-4.0
                """, toc: """
                    - file: intro.md
                    - title: Week 1
                      children:
                        - file: week-1/lecture.md
                        - file: week-1/exercises.md
                    - title: Week 2
                      children:
                        - file: week-2/lecture.md
                        - file: week-2/exercises.md
                """)),
                ("intro.md", "# {{book}}\n\nOrganisation, schedule and how to hand in exercises.\n"),
                ("week-1/lecture.md", "(sec-week-1)=\n# Week 1: Lecture\n\n"),
                ("week-1/exercises.md", exerciseSheet(week: 1)),
                ("week-2/lecture.md", "(sec-week-2)=\n# Week 2: Lecture\n\n"),
                ("week-2/exercises.md", exerciseSheet(week: 2)),
            ],
            symbol: "pencil.and.list.clipboard"
        ),
        documentation,
    ]

    private static func exerciseSheet(week: Int) -> String {
        """
        # Week \(week): Exercises

        :::{exercise}
        :label: ex-week-\(week)-1

        Based on {ref}`sec-week-\(week)`, …
        :::

        :::{solution} ex-week-\(week)-1
        :class: dropdown

        Solution.
        :::

        """
    }
}
