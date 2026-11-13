import Foundation

public enum BookProjectError: LocalizedError, Equatable {
    case noConfig(String)
    case emptyTitle
    case parentNotFound
    case entryNotFound
    case cannotMoveIntoItself
    case pageNotFound(String)
    case invalidPath(String)
    case configChangedSince
    case configChangedOnDisk
    case configInvalid(String)
    case invalidFolder(String)

    public var errorDescription: String? {
        switch self {
        case .noConfig(let folder):
            return "“\(folder)” has no myst.yml. Choose the folder of a Jupyter Book 2 project."
        case .emptyTitle:
            return "Please enter a title."
        case .parentNotFound:
            return "The part to add to no longer exists in the table of contents."
        case .entryNotFound:
            return "This entry no longer exists in the table of contents."
        case .cannotMoveIntoItself:
            return "A part cannot be moved into itself."
        case .pageNotFound(let path):
            return "“\(path)” no longer exists."
        case .invalidPath(let path):
            return "“\(path)” is not a valid file name. Use a path inside the book ending in .md, without hidden folders."
        case .configChangedSince:
            return "myst.yml was changed after this action, so it cannot be undone automatically."
        case .configChangedOnDisk:
            return "myst.yml was changed outside the app. The book has been reloaded; please try again."
        case .configInvalid(let problem):
            return "myst.yml cannot be read (\(problem)). Fix it first; the table of contents is not changed until then."
        case .invalidFolder(let path):
            return "“\(path)” is not a folder that can be used. Use a path inside the book, without “..”, hidden or build folders."
        }
    }
}

/// A Jupyter Book 2 project: a folder with `myst.yml` and its Markdown pages.
///
/// Every structural operation (adding pages, later moving/renaming/removing) goes through
/// this type, so the file system and `project.toc` are always updated together.
public struct BookProject {
    public static let configFileName = "myst.yml"
    static let skippedFolders: Set<String> = ["_build", "node_modules", "__pycache__"]

    public let root: URL
    public private(set) var configText: String
    public private(set) var config: MystConfig
    /// Set while myst.yml cannot be read. The book keeps the last settings that could be read
    /// (none when it was opened like this), and structural changes are refused.
    public private(set) var configProblem: ConfigProblem?
    /// The book's table of contents: `project.toc`, or the inferred file list when there is none.
    public private(set) var toc: [TOCEntry]
    /// Markdown files in the project, relative to `root`, sorted.
    public private(set) var markdownFiles: [String]
    /// Page titles from front matter or the first `# ` heading, keyed by relative path.
    public private(set) var pageTitles: [String: String]
    /// Images in the project (relative paths, sorted), for figures.
    public private(set) var imageFiles: [String] = []
    /// BibTeX files in the project (relative paths, sorted).
    public private(set) var bibFiles: [String] = []
    /// Where new pages, figures, downloads and plugins go (`.jupyterbooknook.yml`).
    public private(set) var folders = BookFolders.defaults

    /// Figures. PDF figures are converted for the web by MyST, which needs ImageMagick and Ghostscript.
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "webp", "tif", "tiff", "pdf"]
    /// Moves a file to the Trash and returns its new location. Tests replace it with a folder.
    var trash: (URL) throws -> URL = FileOperationRunner.systemTrash

    public var configURL: URL { root.appendingPathComponent(Self.configFileName) }
    public var hasExplicitTOC: Bool { config.toc != nil }
    public var title: String { config.title ?? root.lastPathComponent }

    public init(root: URL) throws {
        self.root = root.standardizedFileURL
        let configURL = self.root.appendingPathComponent(Self.configFileName)
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw BookProjectError.noConfig(root.lastPathComponent)
        }
        configText = try String(contentsOf: configURL, encoding: .utf8)
        do {
            config = try MystConfig(yaml: configText)
        } catch {
            config = MystConfig()
            configProblem = ConfigProblem(error)
        }
        toc = []
        markdownFiles = []
        pageTitles = [:]
        rescanFiles()
    }

    // MARK: Reading

    /// Re-reads `myst.yml` and the file list, e.g. after an external edit. When myst.yml cannot be
    /// read, the last settings stay and `configProblem` says why.
    public mutating func reload() throws {
        let text = try String(contentsOf: configURL, encoding: .utf8)
        do {
            config = try MystConfig(yaml: text)
            configProblem = nil
        } catch {
            configProblem = ConfigProblem(error)
        }
        configText = text
        rescanFiles()
    }

    /// Re-reads the title of one known page after it was saved, without scanning the folder.
    /// Returns whether the title changed.
    @discardableResult
    public mutating func refreshTitle(of path: String) -> Bool {
        let title = Self.readTitle(of: root.appendingPathComponent(path))
        guard title != pageTitles[path] else { return false }
        pageTitles[path] = title
        return true
    }

    /// Refuses a change while myst.yml cannot be read.
    func requireReadableConfig() throws {
        if let configProblem { throw BookProjectError.configInvalid(configProblem.description) }
    }

    mutating func rescanFiles() {
        folders = Self.readFolders(in: root)
        let found = Self.findFiles(in: root)
        markdownFiles = found.markdown
        imageFiles = found.images
        bibFiles = found.bibliographies
        pageTitles = Dictionary(uniqueKeysWithValues: markdownFiles.compactMap { path in
            Self.readTitle(of: root.appendingPathComponent(path)).map { (path, $0) }
        })
        var ids = StableIDs()
        toc = config.toc ?? markdownFiles.map { TOCEntry(kind: .file($0), id: ids.next(for: .file($0), title: nil)) }
    }

    public func displayTitle(for entry: TOCEntry) -> String {
        if let title = entry.title { return title }
        switch entry.kind {
        case .file(let path):
            return pageTitles[Self.normalized(path)] ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        case .pattern(let pattern): return pattern
        case .url(let url): return url
        case .group: return "Untitled part"
        }
    }

    public func fileExists(_ path: String) -> Bool {
        markdownFiles.contains(Self.normalized(path))
    }

    /// Markdown files that the explicit table of contents does not include.
    public var filesNotInTOC: [String] {
        guard hasExplicitTOC else { return [] }
        let listed = Set(toc.allFiles.map(Self.normalized))
        let patterns = toc.allPatterns
        return markdownFiles.filter { file in
            !listed.contains(file) && !patterns.contains { Self.glob($0, matches: file) }
        }
    }

    // MARK: Structural operations
    //
    // Each operation computes the new table of contents and the file operations, then
    // `commit` performs them together. Every operation can be undone with `revert`.

    /// Creates a new page and adds it to the table of contents: in `parentID` (the top level when nil),
    /// at `index` (the end when nil). `template` gives the page's text; by default just the heading.
    @discardableResult
    public mutating func addPage(title: String, under parentID: UUID? = nil, at index: Int? = nil, template: PageTemplate? = nil, exports: PageExports? = nil) throws -> (path: String, change: StructuralChange) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BookProjectError.emptyTitle }

        var newTOC = toc
        let path = uniqueFileName(for: trimmed, in: folders.pages)
        guard newTOC.insertEntry(.file(path), under: parentID, at: index ?? .max) else { throw BookProjectError.parentNotFound }
        let summary = hasExplicitTOC
            ? "Added “\(trimmed)” — myst.yml updated"
            : "Added “\(trimmed)” — myst.yml now lists the table of contents"
        let rendered: String = template?.render(TemplateValues(title: trimmed, author: ProjectSettings(yaml: configText).authors.first?.name ?? "", book: self.title)) ?? "# \(trimmed)\n\n"
        var contents = rendered
        if let exports, !exports.isEmpty { contents = try exports.applying(to: contents, page: path) }
        let operation = FileOperation.created(url(for: path), contents: contents)
        return (path, try commit(toc: newTOC, operations: [operation], summary: summary))
    }

    // MARK: Bibliographies and files from outside

    /// BibTeX files in the project that `project.bibliography` does not list.
    public var unlistedBibFiles: [String] {
        let listed = Set(config.bibliography.map { Self.normalized($0, defaultExtension: "bib") })
        return bibFiles.filter { !listed.contains($0) }
    }

    /// Adds BibTeX files to `project.bibliography`, keeping the ones already listed.
    @discardableResult
    public mutating func addBibliographies(_ files: [String]) throws -> StructuralChange? {
        let new = files.filter { !config.bibliography.contains($0) }
        guard !new.isEmpty else { return nil }
        let names = new.joined(separator: ", ")
        return try commit(toc: nil, summary: "Added \(names) to the bibliography — myst.yml updated") { text in
            try Self.addingBibliographies(new, to: text)
        }
    }

    static func addingBibliographies(_ files: [String], to text: String) throws -> String {
        let old = ProjectSettings(yaml: text)
        var new = old
        new.bibliography += files.filter { !old.bibliography.contains($0) }
        return try new.applying(to: text, from: old)
    }

    /// What happens to a file dropped into the book from outside.
    public enum ImportKind: Equatable {
        /// A Markdown page: copied next to the target page and added to the table of contents.
        case page
        /// An image: copied into the figures folder (a PDF into the downloads folder).
        case image
        /// A BibTeX file: copied into the book folder and added to the bibliography.
        case bibliography
        /// Anything else: copied into the downloads folder.
        case other
    }

    public static func importKind(of url: URL) -> ImportKind {
        let ext = url.pathExtension.lowercased()
        if ext == "md" { return .page }
        if ext == "bib" { return .bibliography }
        if imageExtensions.contains(ext) { return .image }
        return .other
    }

    /// Copies files from outside into the book as one undoable change. Pages go into `folder`
    /// (relative, "" for the book folder; the pages folder when nil) and into the table of contents
    /// under `parentID` at `index`; images into the figures folder, BibTeX files into the book
    /// folder (and the bibliography), other files into the downloads folder. PDFs are downloads,
    /// unless `pdfsAreFigures` (dropped into a page as figures). Files already inside the book are
    /// not copied; pages among them are only added to the table of contents. Returns the project
    /// paths of the files.
    @discardableResult
    public mutating func importFiles(_ urls: [URL], folder: String? = nil, under parentID: UUID? = nil, at index: Int? = nil,
                                     pdfsAreFigures: Bool = false) throws -> (paths: [String], change: StructuralChange) {
        var newTOC = toc
        var operations: [FileOperation] = []
        var paths: [String] = []
        var newBibs: [String] = []
        var taken = Set<String>()
        var position = index ?? .max
        for url in urls {
            let kind = Self.importKind(of: url)
            let path: String
            if let inside = relativePath(of: url) {
                path = inside
            } else {
                let base: String
                switch kind {
                case .page: base = folder ?? folders.pages
                case .image: base = url.pathExtension.lowercased() == "pdf" && !pdfsAreFigures ? folders.downloads : folders.figures
                case .bibliography: base = ""
                case .other: base = folders.downloads
                }
                let data = try Data(contentsOf: url)
                let plain = base.isEmpty ? url.lastPathComponent : base + "/" + url.lastPathComponent
                if kind != .page, (try? Data(contentsOf: self.url(for: plain))) == data {
                    // The same file is already there (dropped before): use it, no copy.
                    path = plain
                } else {
                    path = uniquePath(folder: base, name: url.lastPathComponent, taken: taken)
                    taken.insert(path)
                    operations.append(.createdData(self.url(for: path), data))
                }
            }
            paths.append(path)
            if kind == .page, !toc.allFiles.map(Self.normalized).contains(path) {
                guard newTOC.insertEntry(.file(path), under: parentID, at: position) else { throw BookProjectError.parentNotFound }
                if position != .max { position += 1 }
            }
            if kind == .bibliography, !config.bibliography.contains(path) { newBibs.append(path) }
        }
        let names = urls.map(\.lastPathComponent).joined(separator: ", ")
        let tocChanged = newTOC != toc
        let summary = "Added \(names)" + (tocChanged || !newBibs.isEmpty ? " — myst.yml updated" : "")
        let change = try commit(toc: tocChanged ? newTOC : nil, operations: operations, summary: summary,
                                config: newBibs.isEmpty ? nil : { try Self.addingBibliographies(newBibs, to: $0) })
        return (paths, change)
    }

    /// `folder/name`, with -2, -3, … before the extension when that file exists.
    func uniquePath(folder: String, name: String, taken: Set<String> = []) -> String {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        func join(_ file: String) -> String { Self.path(in: folder, file) }
        var candidate = join(name)
        var n = 2
        while taken.contains(candidate) || FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path) {
            candidate = join(ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)")
            n += 1
        }
        return candidate
    }

    /// Saves a pasted image (PNG data) as `<figures folder>/<name>.png`, with -2, -3, … when taken,
    /// as an undoable change. Returns its path.
    public mutating func addPastedImage(_ png: Data, name: String) throws -> (path: String, change: StructuralChange) {
        let path = uniquePath(folder: folders.figures, name: name + ".png")
        let change = try addFile(path, data: png, summary: "Pasted \(path)")
        return (path, change)
    }

    /// Adds a new file with `data` (e.g. an SVG made from a PDF figure) as an undoable change.
    @discardableResult
    public mutating func addFile(_ path: String, data: Data, summary: String) throws -> StructuralChange {
        try commit(toc: nil, operations: [.createdData(url(for: path), data)], summary: summary)
    }

    /// How a figure refers to an image: a PDF as `name.*`, so MyST picks an SVG made from it for
    /// the web (or converts the PDF itself) and the PDF for LaTeX.
    public static func figureReference(to image: String, from page: String) -> String {
        let reference = Self.reference(to: image, from: page)
        guard (image as NSString).pathExtension.lowercased() == "pdf" else { return reference }
        return (reference as NSString).deletingPathExtension + ".*"
    }

    /// Replaces the text of a file in the book (e.g. an edited BibTeX entry) as an undoable change.
    @discardableResult
    public mutating func editFile(_ path: String, from before: String, to after: String, summary: String) throws -> StructuralChange? {
        guard before != after else { return nil }
        return try commit(toc: nil, operations: [.edited(url(for: path), before: before, after: after)], summary: summary)
    }

    /// Adds an empty part (a titled group) at `index` of the top level (the end when nil).
    @discardableResult
    public mutating func addPart(title: String, at index: Int? = nil) throws -> StructuralChange {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BookProjectError.emptyTitle }
        var newTOC = toc
        newTOC.insertEntry(.group(trimmed), under: nil, at: index ?? .max)
        return try commit(toc: newTOC, summary: "Added part “\(trimmed)” — myst.yml updated")
    }

    /// Adds an existing Markdown file (for example one from `filesNotInTOC`) to the table of contents.
    @discardableResult
    public mutating func addExistingFile(_ path: String, under parentID: UUID? = nil, at index: Int? = nil) throws -> StructuralChange {
        let file = Self.normalized(path)
        guard markdownFiles.contains(file) else { throw BookProjectError.pageNotFound(file) }
        var newTOC = toc
        guard newTOC.insertEntry(.file(file), under: parentID, at: index ?? .max) else { throw BookProjectError.parentNotFound }
        return try commit(toc: newTOC, summary: "Added “\(pageTitles[file] ?? file)” to the book — myst.yml updated")
    }

    /// Moves an entry (with its children) into `parentID` (the top level when nil). `index` counts the
    /// parent's children before the move, as in SwiftUI's `onMove`. Returns nil when nothing changes.
    @discardableResult
    public mutating func moveEntry(_ id: UUID, toParent parentID: UUID?, at index: Int) throws -> StructuralChange? {
        guard let entry = toc.entry(id: id), let old = toc.location(of: id) else { throw BookProjectError.entryNotFound }
        if let parentID {
            guard !entry.contains(parentID) else { throw BookProjectError.cannotMoveIntoItself }
            guard toc.entry(id: parentID) != nil else { throw BookProjectError.parentNotFound }
        }
        var target = index
        if old.parent == parentID && old.index < index { target -= 1 }
        if old.parent == parentID && old.index == target { return nil }

        var newTOC = toc
        newTOC.removeEntry(id: id)
        newTOC.insertEntry(entry, under: parentID, at: target)
        return try commit(toc: newTOC, summary: "Moved “\(displayTitle(for: entry))” — myst.yml updated")
    }

    /// Moves an entry up (negative `offset`) or down among its siblings. Returns nil at either end.
    @discardableResult
    public mutating func moveEntry(_ id: UUID, by offset: Int) throws -> StructuralChange? {
        guard let old = toc.location(of: id), let siblings = toc.children(of: old.parent) else {
            throw BookProjectError.entryNotFound
        }
        let newIndex = old.index + offset
        guard siblings.indices.contains(newIndex) else { return nil }
        return try moveEntry(id, toParent: old.parent, at: offset > 0 ? newIndex + 1 : newIndex)
    }

    /// Removes an entry from the table of contents; the file stays on disk. Children of the entry
    /// (the chapters of a part) stay in the book at its position.
    @discardableResult
    public mutating func removeEntry(_ id: UUID) throws -> StructuralChange {
        guard let entry = toc.entry(id: id) else { throw BookProjectError.entryNotFound }
        var newTOC = toc
        newTOC.dissolveEntry(id: id)
        let what = entry.isGroup ? "part “\(displayTitle(for: entry))”" : "“\(displayTitle(for: entry))” from the book"
        return try commit(toc: newTOC, summary: "Removed \(what) — myst.yml updated")
    }

    /// Moves a page to the Trash and removes every table-of-contents entry for it.
    @discardableResult
    public mutating func trashPage(_ path: String) throws -> StructuralChange {
        let file = Self.normalized(path)
        guard markdownFiles.contains(file) else { throw BookProjectError.pageNotFound(file) }
        var newTOC = toc
        let ids = Self.entries(in: toc, forFile: file).map(\.id)
        ids.forEach { newTOC.dissolveEntry(id: $0) }
        let title = pageTitles[file] ?? file
        return try commit(
            toc: ids.isEmpty ? nil : newTOC,
            operations: [.trashed(url(for: file))],
            summary: ids.isEmpty ? "Moved “\(title)” to the Trash" : "Moved “\(title)” to the Trash — myst.yml updated"
        )
    }

    /// Renames a part.
    @discardableResult
    public mutating func renamePart(_ id: UUID, to title: String) throws -> StructuralChange? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BookProjectError.emptyTitle }
        guard let entry = toc.entry(id: id) else { throw BookProjectError.entryNotFound }
        guard entry.title != trimmed else { return nil }
        var newTOC = toc
        newTOC.updateAll { if $0.id == id { $0.title = trimmed } }
        return try commit(toc: newTOC, summary: "Renamed part to “\(trimmed)” — myst.yml updated")
    }

    /// Changes a page's title (in its front matter or first heading) and/or moves its file to `newPath`,
    /// as one undoable change. Moving updates `myst.yml` and the links, `{include}`s and figures in
    /// every page that point to the file, and the page's own relative links.
    /// Returns the page's path afterwards, and nil for the change when nothing changes.
    @discardableResult
    public mutating func renamePage(_ path: String, title: String? = nil, newPath: String? = nil) throws -> (path: String, change: StructuralChange?) {
        let file = Self.normalized(path)
        guard markdownFiles.contains(file) else { throw BookProjectError.pageNotFound(file) }
        var operations: [FileOperation] = []
        var newTOC = toc
        var text = try String(contentsOf: url(for: file), encoding: .utf8)
        var summaryParts: [String] = []

        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), title != pageTitles[file] {
            guard !title.isEmpty else { throw BookProjectError.emptyTitle }
            let retitled = Self.settingTitle(title, in: text)
            operations.append(.edited(url(for: file), before: text, after: retitled))
            text = retitled
            // A title written in myst.yml overrides the page's own, so keep it in step.
            newTOC.updateAll { entry in
                if entry.file.map(Self.normalized) == file, entry.title != nil { entry.title = title }
            }
            summaryParts.append("Renamed page to “\(title)”")
        }

        var finalPath = file
        if let newPath {
            let destination = try validatedPagePath(newPath)
            if destination != file {
                operations.append(.moved(from: url(for: file), to: url(for: destination)))
                let ownLinks = Self.rewritingReferences(in: text, page: file, newPage: destination, movedFrom: file, movedTo: destination)
                if ownLinks != text {
                    operations.append(.edited(url(for: destination), before: text, after: ownLinks))
                }
                for other in markdownFiles where other != file {
                    guard let before = try? String(contentsOf: url(for: other), encoding: .utf8) else { continue }
                    let after = Self.rewritingReferences(in: before, page: other, newPage: other, movedFrom: file, movedTo: destination)
                    if after != before { operations.append(.edited(url(for: other), before: before, after: after)) }
                }
                newTOC.updateAll { entry in
                    if let listed = entry.file, Self.normalized(listed) == file {
                        entry.kind = .file(ProjectPath.reference(to: destination, from: Self.configFileName, like: listed))
                    }
                }
                let updatedPages = operations.filter { if case .edited(let url, _, _) = $0 { return url != self.url(for: file) } else { return false } }.count
                summaryParts.append("Moved to \(destination)" + (updatedPages > 0 ? ", links in \(updatedPages) page\(updatedPages == 1 ? "" : "s") updated" : ""))
                finalPath = destination
            }
        }

        guard !operations.isEmpty || newTOC != toc else { return (file, nil) }
        let tocChanged = newTOC != toc
        let summary = summaryParts.joined(separator: "; ") + (tocChanged ? " — myst.yml updated" : "")
        return (finalPath, try commit(toc: tocChanged ? newTOC : nil, operations: operations, summary: summary))
    }

    /// Writes `newTOC` into `myst.yml` (when non-nil; only the `toc` block changes) and performs
    /// `operations`, all or nothing.
    mutating func commit(toc newTOC: [TOCEntry]?, operations: [FileOperation] = [], summary: String,
                         config transform: ((String) throws -> String)? = nil) throws -> StructuralChange {
        let onDisk = try String(contentsOf: configURL, encoding: .utf8)
        guard onDisk == configText else {
            try reload()
            throw BookProjectError.configChangedOnDisk
        }
        if newTOC != nil || transform != nil { try requireReadableConfig() }
        let before = configText
        var after = before
        if let newTOC {
            after = try TOCWriter.replacingTOC(in: before, with: newTOC)
        }
        if let transform {
            after = try transform(after)
        }
        if after != before {
            _ = try MystConfig(yaml: after) // never write a file we cannot read back
        }
        let runner = FileOperationRunner(trash: trash)
        let done = try runner.perform(operations)
        if after != before {
            do {
                try after.write(to: configURL, atomically: true, encoding: .utf8)
            } catch {
                runner.rollBack(done)
                throw error
            }
        }
        try reload()
        return StructuralChange(summary: summary, configBefore: before, configAfter: after, fileOperations: done)
    }

    /// Writes settings into `myst.yml`: only the keys that differ from `old` change.
    /// Returns nil when nothing changed.
    public mutating func applySettings(_ settings: ProjectSettings, from old: ProjectSettings, summary: String) throws -> StructuralChange? {
        let onDisk = try String(contentsOf: configURL, encoding: .utf8)
        guard onDisk == configText else {
            try reload()
            throw BookProjectError.configChangedOnDisk
        }
        try requireReadableConfig()
        let after = try settings.applying(to: configText, from: old)
        guard after != configText else { return nil }
        _ = try MystConfig(yaml: after) // never write a file we cannot read back
        let before = configText
        try after.write(to: configURL, atomically: true, encoding: .utf8)
        try reload()
        return StructuralChange(summary: summary, configBefore: before, configAfter: after, fileOperations: [])
    }

    /// The exports and downloads in a page's front matter.
    public func pageExports(_ path: String) -> PageExports {
        guard let text = try? String(contentsOf: url(for: Self.normalized(path)), encoding: .utf8) else { return PageExports() }
        return PageExports(page: text)
    }

    /// Writes exports and downloads into the front matter of several pages, as one undoable change.
    /// Pages whose text would not change are left alone; returns nil when none changes.
    public mutating func setPageExports(_ changes: [String: PageExports], summary: String) throws -> StructuralChange? {
        var operations: [FileOperation] = []
        for (path, exports) in changes.sorted(by: { $0.key < $1.key }) {
            let file = url(for: Self.normalized(path))
            let before = try String(contentsOf: file, encoding: .utf8)
            let after = try exports.applying(to: before, page: Self.normalized(path))
            if after != before { operations.append(.edited(file, before: before, after: after)) }
        }
        guard !operations.isEmpty else { return nil }
        return try commit(toc: nil, operations: operations, summary: summary)
    }

    /// Undoes a structural change and returns the change that redoes it.
    /// Refused when `myst.yml` or an affected page has been edited since.
    @discardableResult
    public mutating func revert(_ change: StructuralChange) throws -> StructuralChange {
        if change.changesConfig {
            let current = try String(contentsOf: configURL, encoding: .utf8)
            guard current == change.configAfter else { throw BookProjectError.configChangedSince }
        }
        let runner = FileOperationRunner(trash: trash)
        let inverse = try change.fileOperations.reversed().map(runner.inverse)
        let done = try runner.perform(inverse)
        if change.changesConfig {
            do {
                try change.configBefore.write(to: configURL, atomically: true, encoding: .utf8)
            } catch {
                runner.rollBack(done)
                throw error
            }
        }
        try reload()
        return StructuralChange(summary: change.summary, configBefore: change.configAfter, configAfter: change.configBefore, fileOperations: done)
    }

    // MARK: Paths, titles and references

    public func url(for path: String) -> URL {
        root.appendingPathComponent(path)
    }

    /// The project-relative path of a file URL, or nil when it is outside the project.
    public func relativePath(of url: URL) -> String? {
        let base = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : nil
    }

    /// Checks a user-entered page path and returns it normalised: relative, ending in `.md`, inside the book.
    func validatedPagePath(_ input: String) throws -> String {
        var path = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.hasPrefix("/") { path.removeFirst() }
        if URL(fileURLWithPath: path).pathExtension.isEmpty { path += ".md" }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard URL(fileURLWithPath: path).pathExtension.lowercased() == "md",
              let normalized = ProjectPath.normalize(components),
              !normalized.split(separator: "/").contains(where: { $0.hasPrefix(".") || Self.skippedFolders.contains(String($0)) })
        else { throw BookProjectError.invalidPath(input) }
        return normalized
    }

    /// Every table-of-contents entry that lists `path`, in book order.
    public func entries(forFile path: String) -> [TOCEntry] {
        Self.entries(in: toc, forFile: Self.normalized(path))
    }

    static func entries(in toc: [TOCEntry], forFile file: String) -> [TOCEntry] {
        toc.flatMap { entry in
            (entry.file.map(normalized) == file ? [entry] : []) + entries(in: entry.children, forFile: file)
        }
    }

    /// Rewrites references in the text of `page` (which itself moves to `newPage`) after
    /// `movedFrom` moved to `movedTo`, keeping each reference's style.
    static func rewritingReferences(in text: String, page: String, newPage: String, movedFrom: String, movedTo: String) -> String {
        LinkRewriter.rewrite(text) { target in
            guard let resolved = ProjectPath.resolve(target, from: page) else { return nil }
            let pointsToMoved = normalized(resolved) == movedFrom
            guard pointsToMoved || newPage != page else { return nil }
            return ProjectPath.reference(to: pointsToMoved ? movedTo : resolved, from: newPage, like: target)
        }
    }

    /// Where a page's title comes from: a `title:` line in front matter, else the first level-1 heading.
    enum TitleSource {
        case frontMatter(line: Int)
        case heading(line: Int)
        /// No title; `frontMatterEnd` is the index of the closing `---`, if there is front matter.
        case none(frontMatterEnd: Int?)
    }

    static func titleSource(in lines: [String]) -> TitleSource {
        var bodyStart = 0
        var frontMatterEnd: Int?
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            var i = 1
            var titleLine: Int?
            while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "---" {
                if titleLine == nil, lines[i].hasPrefix("title:"),
                   !lines[i].dropFirst("title:".count).trimmingCharacters(in: .whitespaces).isEmpty {
                    titleLine = i
                }
                i += 1
            }
            if i < lines.count {
                if let titleLine { return .frontMatter(line: titleLine) }
                frontMatterEnd = i
                bodyStart = i + 1
            }
        }
        var fence: (char: Character, length: Int)?
        for i in bodyStart..<max(bodyStart, lines.count) {
            let line = lines[i]
            let trimmed = line.drop(while: { $0 == " " })
            if let first = trimmed.first, first == "`" || first == "~" {
                let run = trimmed.prefix(while: { $0 == first }).count
                if run >= 3 {
                    if let open = fence {
                        if open.char == first, run >= open.length, trimmed.dropFirst(run).allSatisfy(\.isWhitespace) { fence = nil }
                    } else {
                        fence = (first, run)
                    }
                    continue
                }
            }
            if fence == nil, line.hasPrefix("# ") { return .heading(line: i) }
        }
        return .none(frontMatterEnd: frontMatterEnd)
    }

    /// `text` with its title changed to `title`, wherever the title is written.
    static func settingTitle(_ title: String, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        switch titleSource(in: lines) {
        case .frontMatter(let line):
            lines[line] = "title: " + TOCWriter.scalar(title)
        case .heading(let line):
            lines[line] = "# " + title
        case .none(let frontMatterEnd?):
            lines.insert("title: " + TOCWriter.scalar(title), at: frontMatterEnd)
        case .none(nil):
            lines.insert(contentsOf: ["# " + title, ""], at: 0)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    /// A file-name stem for a page title: "Gradient Descent" → "gradient-descent".
    public static func slug(for title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var slug = ""
        var lastWasDash = false
        for scalar in folded.unicodeScalars {
            if scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash && !slug.isEmpty {
                slug.append("-")
                lastWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "untitled" : slug
    }

    func uniqueFileName(for title: String, in folder: String = "") -> String {
        let taken = Set(markdownFiles).union(toc.allFiles.map(Self.normalized))
        return uniquePath(folder: folder, name: Self.slug(for: title) + ".md", taken: taken)
    }

    /// TOC paths may start with `./` and may omit the `.md` extension.
    public static func normalized(_ path: String) -> String { normalized(path, defaultExtension: "md") }

    static func normalized(_ path: String, defaultExtension: String) -> String {
        var p = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
        if URL(fileURLWithPath: p).pathExtension.isEmpty { p += "." + defaultExtension }
        return p
    }

    /// Markdown pages, images and BibTeX files under `root`, skipping hidden and build folders.
    static func findFiles(in root: URL) -> (markdown: [String], images: [String], bibliographies: [String]) {
        let rootPath = root.resolvingSymlinksInPath().path
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return ([], [], []) }

        var markdown: [String] = [], images: [String] = [], bibliographies: [String] = []
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                if skippedFolders.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            let ext = url.pathExtension.lowercased()
            guard ext == "md" || ext == "bib" || imageExtensions.contains(ext) else { continue }
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relative = String(path.dropFirst(rootPath.count + 1))
            switch ext {
            case "md": markdown.append(relative)
            case "bib": bibliographies.append(relative)
            default: images.append(relative)
            }
        }
        return (markdown.sorted(), images.sorted(), bibliographies.sorted())
    }

    /// The `title:` from front matter, else the first level-1 heading outside code blocks.
    static func readTitle(of url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n")
        switch titleSource(in: lines) {
        case .frontMatter(let line):
            let value = lines[line].dropFirst("title:".count).trimmingCharacters(in: .whitespaces)
            let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return unquoted.isEmpty ? nil : unquoted
        case .heading(let line):
            return lines[line].dropFirst(2).trimmingCharacters(in: .whitespaces)
        case .none:
            return nil
        }
    }

    /// Matches TOC `pattern:` globs: `*` and `?` within one path segment, `**` across segments.
    static func glob(_ pattern: String, matches path: String) -> Bool {
        var regex = "^"
        let chars = Array(normalizedPattern(pattern))
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "*" && i + 1 < chars.count && chars[i + 1] == "*" {
                if i + 2 < chars.count && chars[i + 2] == "/" {
                    regex += "(.*/)?"
                    i += 3
                } else {
                    regex += ".*"
                    i += 2
                }
                continue
            }
            switch c {
            case "*": regex += "[^/]*"
            case "?": regex += "[^/]"
            default: regex += NSRegularExpression.escapedPattern(for: String(c))
            }
            i += 1
        }
        regex += "$"
        return path.range(of: regex, options: .regularExpression) != nil
    }

    private static func normalizedPattern(_ pattern: String) -> String {
        pattern.hasPrefix("./") ? String(pattern.dropFirst(2)) : pattern
    }
}
