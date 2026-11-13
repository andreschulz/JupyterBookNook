import AppKit
@preconcurrency import BookModel
import BuildService
import Foundation
import MystSyntax
import Observation
import ProjectIndex
import SwiftUI

/// Editor only, editor and preview side by side, or preview only.
enum ViewMode: String, CaseIterable, Identifiable {
    case editor, split, preview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .editor: return "Editor"
        case .split: return "Split"
        case .preview: return "Preview"
        }
    }

    var showsEditor: Bool { self != .preview }
    var showsPreview: Bool { self != .editor }
}

/// The tabs of the Project Settings screen (mockup 04): settings of the open book, written to
/// myst.yml (and a few of this app's settings for the book). Bibliography is its own screen.
enum SettingsTab: String, CaseIterable, Identifiable {
    case project = "Project"
    case site = "Site & theme"
    case math = "Math & numbering"
    case execution = "Execution"
    case exports = "Exports"
    case bibliography = "Bibliography"
    case plugins = "Plugins"
    case style = "Style"

    var id: String { rawValue }

    /// The tabs of the Project Settings screen itself; Bibliography, Plugins and Style are screens of their own.
    static var formTabs: [SettingsTab] { allCases.filter { !$0.isOwnScreen } }

    var isOwnScreen: Bool { self == .bibliography || self == .plugins || self == .style }
}

/// The tabs of the Settings window (⌘,): the app's settings, the same for every book.
enum AppSettingsTab: String, CaseIterable, Identifiable {
    case editor = "Editor"
    case templates = "Templates"
    case plugins = "Plugins"
    case myst = "MyST"

    var id: String { rawValue }
}

enum RenameRequest: Identifiable {
    case page(String)
    case part(UUID)

    var id: String {
        switch self {
        case .page(let path): return "page:" + path
        case .part(let id): return "part:" + id.uuidString
        }
    }
}

/// App state for the open book: the project, open tabs and transient UI state.
@MainActor
@Observable
final class BookStore {
    struct Notice: Identifiable {
        let id = UUID()
        let message: String
        let change: StructuralChange?
    }

    var project: BookProject?
    /// Builds, the live preview and the MyST installation for the open book.
    let build = BuildController()
    /// Keeps editor and preview on the same section in Split view.
    let scrollSync = ScrollSync()
    /// Labels, citations and files of the book, for completion and diagnostics.
    var index = ProjectIndex()
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    /// The editor's text view for the current tab, for Find.
    @ObservationIgnored weak var editorTextView: NSTextView?
    /// Pending re-index per page; one per page, so switching tabs right after typing does not
    /// cancel the update of the page just edited.
    @ObservationIgnored private var indexUpdateTasks: [String: Task<Void, Never>] = [:]
    var documents: [OpenDocument] = []
    var currentPath: String? {
        didSet { if currentPath != oldValue { scrollSync.pageChanged() } }
    }
    /// The Project Settings screen replaces the editor while a tab of it is chosen.
    var settingsTab: SettingsTab?
    var isShowingNewProject = false
    /// The ⌘T overlay that inserts a snippet at the cursor.
    var isShowingSnippets = false
    /// Quick Open (⌘P) or the command palette (⇧⌘P), shown over the window.
    var palette: PaletteMode?
    var isShowingExport = false
    /// Files not in the table of contents that the user chose to ignore, per book.
    private(set) var ignoredFiles: Set<String> = []
    /// Per-page exports: each page lists its own documents in its front matter. The switch is a
    /// setting of this app, per book.
    var pageExportsEnabled = false {
        didSet { saveBookSetting(pageExportsEnabled, "pageExports.enabled") }
    }
    var errorMessage: String?
    var notice: Notice?
    /// The short tour of the main features, shown once when the first book opens (Help › Welcome Tour).
    var isShowingTour = false
    /// The New Plugin sheet of the Plugins screen.
    var isShowingNewPlugin = false

    // MARK: Recent books

    struct RecentBook: Identifiable, Equatable {
        var path: String
        var title: String
        var id: String { path }
    }

    /// Books opened before, most recent first, for the welcome screen and File › Open Recent.
    private(set) var recentBooks: [RecentBook] = BookStore.loadRecents()

    private static func loadRecents() -> [RecentBook] {
        let stored = UserDefaults.standard.array(forKey: "recentBooks") as? [[String: String]] ?? []
        return stored.compactMap { item in
            guard let path = item["path"], FileManager.default.fileExists(atPath: path + "/" + BookProject.configFileName) else { return nil }
            return RecentBook(path: path, title: item["title"] ?? (path as NSString).lastPathComponent)
        }
    }

    private func remember(_ project: BookProject) {
        let path = project.root.standardizedFileURL.path
        recentBooks.removeAll { $0.path == path }
        recentBooks.insert(RecentBook(path: path, title: project.title), at: 0)
        recentBooks = Array(recentBooks.prefix(8))
        UserDefaults.standard.set(recentBooks.map { ["path": $0.path, "title": $0.title] }, forKey: "recentBooks")
        NSDocumentController.shared.noteNewRecentDocumentURL(project.root)
    }

    func clearRecentBooks() {
        recentBooks = []
        UserDefaults.standard.removeObject(forKey: "recentBooks")
    }

    // MARK: Plugins

    /// What each plugin of the open book adds, by its source; read in the background
    /// (BookStore+Plugins).
    var pluginStatus: [String: PluginStatus] = [:]
    /// Plugins switched off in the Plugins screen: taken out of myst.yml and kept here, per book,
    /// so they can be switched on again.
    var disabledPlugins: [PluginEntry] = [] {
        didSet { saveBookSetting(disabledPlugins.map(\.yaml), "plugins.disabled") }
    }
    @ObservationIgnored var pluginTask: Task<Void, Never>?
    /// The plugin sources the last inspection covered, to notice when myst.yml lists others.
    @ObservationIgnored var inspectedPlugins: [String]?
    /// The plugin library, for all books (Settings › Plugins), and what each of its plugins adds.
    var pluginLibrary: [LibraryPlugin] = []
    var libraryStatus: [String: PluginStatus] = [:]
    @ObservationIgnored var libraryTask: Task<Void, Never>?

    // MARK: Spelling

    /// The spell-checking language for the open book (an identifier like "de" or "en_GB"); empty
    /// lets macOS detect the language. A setting of this app, per book.
    var spellingLanguage = "" {
        didSet {
            saveBookSetting(spellingLanguage, "spelling")
            applySpellingLanguage()
        }
    }

    @ObservationIgnored private var setsSpellingLanguage = false

    /// The checker is shared by the whole app; there is one book per window and app.
    private func applySpellingLanguage() {
        let checker = NSSpellChecker.shared
        // Leave the checker as the user set it (Edit › Spelling) until a book asks for a language.
        guard !spellingLanguage.isEmpty || setsSpellingLanguage else { return }
        setsSpellingLanguage = !spellingLanguage.isEmpty
        if spellingLanguage.isEmpty {
            checker.automaticallyIdentifiesLanguages = true
        } else {
            checker.automaticallyIdentifiesLanguages = false
            _ = checker.setLanguage(spellingLanguage)
        }
        // Re-check what is on screen in the new language.
        if let textView = editorTextView, textView.isContinuousSpellCheckingEnabled {
            textView.isContinuousSpellCheckingEnabled = false
            textView.isContinuousSpellCheckingEnabled = true
        }
    }
    /// Watches the book folder for changes made outside the app.
    @ObservationIgnored private var watcher: FileWatcher?

    /// A page or part being renamed, shown as a sheet.
    var renameRequest: RenameRequest?
    /// The table the table assistant edits, shown as a sheet.
    var tableAssistant: TableAssistantRequest?
    /// A part of the page the Style screen should show (e.g. tables, from the table assistant).
    var styleElementRequest: String?
    /// A page waiting for confirmation before it is moved to the Trash.
    var pendingTrash: String?

    var isShowingOutline = true
    /// The sidebar column of the window, hidden in focus mode.
    var sidebarVisibility: NavigationSplitViewVisibility = .automatic
    /// Focus mode: only the page, without sidebar, toolbar, tabs and inspector.
    private(set) var isFocusMode = false
    @ObservationIgnored private var beforeFocus: (viewMode: ViewMode, outline: Bool, sidebar: NavigationSplitViewVisibility)?

    /// Shows sidebar and outline again, keeping the current view.
    private func leaveFocusMode() {
        isFocusMode = false
        isShowingOutline = beforeFocus?.outline ?? true
        sidebarVisibility = beforeFocus?.sidebar ?? .automatic
        beforeFocus = nil
    }

    func toggleFocusMode() {
        if isFocusMode {
            isFocusMode = false
            if let before = beforeFocus {
                viewMode = before.viewMode
                isShowingOutline = before.outline
                sidebarVisibility = before.sidebar
            }
            beforeFocus = nil
        } else {
            guard currentDocument != nil else { return }
            beforeFocus = (viewMode, isShowingOutline, sidebarVisibility)
            if viewMode != .editor { viewMode = .editor }
            settingsTab = nil
            isShowingOutline = false
            sidebarVisibility = .detailOnly
            isFocusMode = true
        }
        if let textView = editorTextView {
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }
    /// Counts changes to the book's files (structural changes, undo, saves). Views that read files
    /// directly, such as the per-page exports grid, read it so they redraw.
    private(set) var fileRevision = 0
    /// Parts open in the sidebar, kept across rebuilds of the list.
    var expandedParts: Set<UUID> = []
    var viewMode: ViewMode = ViewMode(rawValue: UserDefaults.standard.string(forKey: "viewMode") ?? "") ?? .split {
        didSet {
            UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode")
            // Choosing a view in the toolbar leaves Project Settings, and Split or Preview leaves focus mode.
            settingsTab = nil
            if isFocusMode, viewMode != .editor { leaveFocusMode() }
            guard let project else { return }
            if viewMode.showsPreview {
                // Show what is on screen, then keep the server running.
                saveAll()
                build.ensurePreview(project.root, askIfMissing: true)
            }
        }
    }
    @ObservationIgnored private var liveSaveTask: Task<Void, Never>?
    var isShowingNewChapter = false
    var isShowingNewPart = false
    /// The part a new chapter is added to; nil means the end of the book.
    var newChapterPart: UUID?

    @ObservationIgnored private var terminationObserver: NSObjectProtocol?

    var currentDocument: OpenDocument? {
        documents.first { $0.path == currentPath }
    }

    init() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue, as requested above.
            MainActor.assumeIsolated { self?.saveAll() }
        }
        scrollSync.context = { [weak self] in
            guard let self else { return ([], false) }
            // Only pages are synced: other tabs do not show the book in the preview.
            return (self.currentDocument?.headings ?? [], self.viewMode == .split && self.currentDocument?.previewKind == .site)
        }
        // `swift run JupyterBookNook path/to/book` opens that book directly.
        if let argument = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            open(URL(fileURLWithPath: argument))
        }
        #if DEBUG
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { if let self { DebugSnapshots.runIfRequested(store: self) } }
        }
        #endif
    }

    // MARK: Opening

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        panel.message = "Choose the project’s folder, the one that contains myst.yml"
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    func open(_ url: URL) {
        if url.standardizedFileURL == Self.documentationFolder.standardizedFileURL {
            saveAll()
            updateDocumentation(url)
        }
        do {
            let project = try BookProject(root: url)
            saveAll()
            self.project = project
            build.bookChanged(to: project.root)
            index = ProjectIndex()
            pluginStatus = [:]
            inspectedPlugins = nil
            disabledPlugins = (UserDefaults.standard.stringArray(forKey: "plugins.disabled." + project.root.standardizedFileURL.path) ?? []).compactMap(PluginEntry.init(yaml:))
            rebuildIndex()
            documents = []
            currentPath = nil
            notice = nil
            settingsTab = nil
            expandedParts = []
            ignoredFiles = Set(UserDefaults.standard.stringArray(forKey: Self.ignoredKey(project.root)) ?? [])
            let defaults = UserDefaults.standard
            addUnlistedBibliographies()
            pageExportsEnabled = defaults.bool(forKey: "pageExports.enabled." + project.root.standardizedFileURL.path)
            spellingLanguage = defaults.string(forKey: "spelling." + project.root.standardizedFileURL.path) ?? ""
            applySpellingLanguage()
            // Snapshot runs (debug) share the app's defaults; they must not change recents or the tour.
            let isSnapshot = ProcessInfo.processInfo.environment["NOOK_SNAPSHOT"] != nil
            if !isSnapshot { remember(project) }
            if !isSnapshot, !defaults.bool(forKey: "onboarding.shown") {
                defaults.set(true, forKey: "onboarding.shown")
                isShowingTour = true
            }
            watcher = FileWatcher(root: project.root) { [weak self] paths in self?.filesChangedOnDisk(paths) }
            if project.configProblem != nil {
                // Opened anyway, so myst.yml can be fixed here.
                openConfigAsText()
            } else if let first = project.toc.allFiles.first(where: project.fileExists) {
                openFile(first)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Follows changes made outside the app: re-reads myst.yml and the file list, updates open
    /// tabs, and re-indexes. Changes the app made itself compare equal and change nothing.
    func filesChangedOnDisk(_ paths: Set<String>) {
        guard var project else { return }
        let configChanged = paths.contains(BookProject.configFileName)
            && (try? String(contentsOf: project.configURL, encoding: .utf8)) != project.configText
        // The app's own saves of pages come back as events too; the index and the sidebar already
        // have those pages (`scheduleIndexUpdate`, `save`), so they need no rescan.
        let ownSaves = Set(documents.filter { document in
            document.isPage && paths.contains(document.path)
                && (try? String(contentsOf: document.url, encoding: .utf8)) == document.savedText
        }.map(\.path))
        let kinds = Set(paths.subtracting(ownSaves).map { ($0 as NSString).pathExtension.lowercased() })
        let filesChanged = !kinds.isDisjoint(with: BookProject.imageExtensions.union(["md", "bib", "css"]))
        for document in documents where paths.contains(document.path) {
            document.diskDidChange()
        }
        let pluginSources = Set(project.plugins.filter { !$0.isURL }.map { BookProject.normalized($0.source) })
        if !pluginSources.isDisjoint(with: paths) {
            inspectPlugins()
            build.pluginsChanged()
        }
        guard configChanged || filesChanged else { return }
        let hadProblem = project.configProblem != nil
        do {
            try project.reload()
        } catch {
            return // myst.yml is being replaced; the next event reads it
        }
        self.project = project
        fileRevision += 1
        if configChanged {
            rebuildIndex()
            if hadProblem, project.configProblem == nil { notice = Notice(message: "myst.yml can be read again", change: nil) }
            // A change in an external editor made the app's undo steps for myst.yml stale; they are
            // refused when undone (`configChangedSince`), so nothing is overwritten.
        } else if kinds.contains("bib") {
            addUnlistedBibliographies()
            rebuildIndex()
        } else {
            rebuildIndex()
        }
        // Tabs of files that were moved or deleted elsewhere.
        for document in documents where !FileManager.default.fileExists(atPath: document.url.path) {
            document.diskDidChange()
            if document.diskConflict == nil { close(document.path) }
        }
    }

    /// Keeps the edits of a tab whose file changed on disk: they are saved over the file.
    func keepMine(_ document: OpenDocument) {
        document.diskConflict = nil
        save(document)
    }

    private func makeDocument(_ path: String, root: URL) throws -> OpenDocument {
        let document = try OpenDocument(path: path, root: root)
        document.diagnostics = index.diagnostics(for: path)
        document.onEdit = { [weak self, weak document] in
            if let document { self?.documentEdited(document) }
        }
        return document
    }

    func openFile(_ path: String) {
        guard let project else { return }
        if !documents.contains(where: { $0.path == path }) {
            do {
                documents.append(try makeDocument(path, root: project.root))
            } catch {
                errorMessage = "Could not open \(path): \(error.localizedDescription)"
                return
            }
        }
        currentPath = path
        settingsTab = nil
        // A PDF or image is shown in the preview, so the preview has to be visible.
        if currentDocument?.isViewOnly == true, viewMode == .editor { viewMode = .split }
    }

    /// Selects the next (`offset` 1) or previous (-1) tab, wrapping around.
    func selectTab(offset: Int) {
        guard !documents.isEmpty else { return }
        let index = documents.firstIndex { $0.path == currentPath } ?? 0
        currentPath = documents[(index + offset + documents.count) % documents.count].path
    }

    // MARK: Project settings and templates

    /// Writes changed settings into myst.yml as one undoable step.
    /// Returns false when they could not be written (the error is shown).
    @discardableResult
    func applySettings(_ settings: ProjectSettings, from old: ProjectSettings, undoManager: UndoManager?) -> Bool {
        var succeeded = true
        perform("Change Settings", undoManager, showsNotice: false) { project in
            do {
                return try project.applySettings(settings, from: old, summary: "Settings changed — myst.yml updated")
            } catch {
                succeeded = false
                throw error
            }
        }
        return succeeded
    }

    /// The tab the Settings window shows; set before opening it.
    var appSettingsTab: AppSettingsTab = AppSettingsTab(rawValue: UserDefaults.standard.string(forKey: "settings.tab") ?? "") ?? .editor {
        didSet { UserDefaults.standard.set(appSettingsTab.rawValue, forKey: "settings.tab") }
    }
    /// SwiftUI's action that opens the Settings window, handed over by the window's view (only
    /// views can read it).
    @ObservationIgnored var openSettingsWindow: (() -> Void)?

    /// Opens the Settings window (⌘,) at `tab`: the app's settings for all books.
    func showAppSettings(_ tab: AppSettingsTab) {
        appSettingsTab = tab
        isShowingSnippets = false
        palette = nil
        openSettingsWindow?()
    }

    /// Opens Project Settings (⌥⌘,) at `tab`: the open book's settings.
    func showSettings(_ tab: SettingsTab = .project) {
        saveAll()
        if isFocusMode { leaveFocusMode() }
        if viewMode == .preview { viewMode = .split }
        settingsTab = tab
    }

    /// Opens myst.yml in a tab, for everything the forms do not cover.
    func openConfigAsText() {
        openFile(BookProject.configFileName)
        if viewMode == .preview { viewMode = .split }
    }

    /// Opens myst.yml as text at the line the YAML parser complained about.
    func showConfigProblem() {
        openConfigAsText()
        guard let line = project?.configProblem?.line, let document = currentDocument else { return }
        document.reveal(document.rangeOfLine(line))
    }

    func ignore(_ path: String) {
        guard let project else { return }
        ignoredFiles.insert(path)
        UserDefaults.standard.set(Array(ignoredFiles).sorted(), forKey: Self.ignoredKey(project.root))
    }

    func unignoreAll() {
        guard let project else { return }
        ignoredFiles = []
        UserDefaults.standard.removeObject(forKey: Self.ignoredKey(project.root))
    }

    private static func ignoredKey(_ root: URL) -> String { "ignored." + root.standardizedFileURL.path }

    private func saveBookSetting(_ value: Any, _ key: String) {
        guard let project else { return }
        UserDefaults.standard.set(value, forKey: key + "." + project.root.standardizedFileURL.path)
    }

    /// Where new pages, figures, downloads and plugins go (Project Settings › Folders).
    func setFolders(_ folders: BookFolders, undoManager: UndoManager?) {
        perform("Change Folders", undoManager, showsNotice: false) { try $0.setFolders(folders) }
    }

    // MARK: Per-page exports

    /// Writes exports and downloads into pages' front matter, as one undo step.
    func setPageExports(_ changes: [String: PageExports], actionName: String, undoManager: UndoManager?) {
        perform(actionName, undoManager, showsNotice: changes.count > 1) { project in
            try project.setPageExports(changes, summary: "\(actionName) — \(changes.count) page\(changes.count == 1 ? "" : "s") updated")
        }
    }

    /// The book's pages (files that exist), as paths of their files.
    var bookPages: [String] {
        guard let project else { return [] }
        return project.toc.allFiles.filter(project.fileExists).map { page in
            project.markdownFiles.first { $0 == page || $0 == page + ".md" } ?? page
        }
    }

    enum Coverage { case none, some, all }

    /// Whether no page, some pages or every page of the book exports `format`.
    func coverage(of format: String) -> Coverage {
        guard let project else { return .none }
        let pages = bookPages
        let count = pages.filter { project.pageExports($0).formats.contains(format) }.count
        return count == 0 ? .none : count == pages.count ? .all : .some
    }

    /// Adds `format` to every page of the book, or removes it from every page.
    func setFormat(_ format: String, onAllPages on: Bool, undoManager: UndoManager?) {
        guard let project else { return }
        var changes: [String: PageExports] = [:]
        for page in bookPages {
            var exports = project.pageExports(page)
            exports.formats.removeAll { $0 == format }
            if on { exports.formats.append(format) }
            changes[page] = exports
        }
        let title = PageExports.title(of: format)
        setPageExports(changes, actionName: on ? "\(title) for All Pages" : "No \(title) for Any Page", undoManager: undoManager)
    }

    /// Creates a book from a template and opens it.
    /// Where Help › JupyterBookNook Documentation keeps its project.
    static var documentationFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JupyterBookNook/Documentation", isDirectory: true)
    }

    /// Opens the documentation project, creating it from the built-in template the first time.
    /// It is an ordinary project; `open` brings it up to date with this app version.
    func openDocumentation() {
        let folder = Self.documentationFolder
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent(BookProject.configFileName).path) {
            open(folder)
        } else {
            let name = TemplateLibrary.documentationName
            createProject(TemplateLibrary.documentation, at: folder, values: TemplateValues(title: name, book: name))
        }
    }

    /// Updates the documentation copy to this app version's pages (see `DocumentationUpdate`),
    /// asking before it replaces pages the user changed.
    private func updateDocumentation(_ folder: URL) {
        let update = DocumentationUpdate(folder: folder)
        var replacing = false
        if !update.changedByUser.isEmpty, ProcessInfo.processInfo.environment["NOOK_SNAPSHOT"] == nil {
            let alert = NSAlert()
            alert.messageText = "Update the JupyterBookNook Documentation?"
            let names = update.changedByUser.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            alert.informativeText = "This version of the app has new versions of pages you changed: \(names).\n\n"
                + "Replacing them loses your changes to these pages. Pages you did not change are updated either way."
            alert.addButton(withTitle: "Keep My Changes")
            alert.addButton(withTitle: "Replace")
            replacing = alert.runModal() == .alertSecondButtonReturn
        }
        do {
            try update.apply(replacingChanges: replacing)
        } catch {
            errorMessage = "The documentation could not be updated: \(error.localizedDescription)"
        }
    }

    /// Sets up `folder` as a project (see `TemplateLibrary.createProject`) and opens it.
    /// `retitle` sets a new title in an existing project's myst.yml (one undo step).
    func createProject(_ template: ProjectTemplate, at folder: URL, values: TemplateValues, retitle: String? = nil) {
        do {
            let root = try TemplateLibrary.createProject(template, at: folder, values: values)
            open(root)
            if let retitle, project?.root == root.standardizedFileURL {
                perform("Change Title", nil) { try $0.setConfigValue(["project", "title"], to: .string(retitle), summary: "Title changed to “\(retitle)”") }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Files from outside, figures and links

    /// Copies files dropped on the sidebar into the book: pages next to `target` (before a page,
    /// at the end of a part, at the end of the book when nil), images into images/, BibTeX files
    /// into the book folder and the bibliography.
    func importFiles(_ urls: [URL], onto target: TOCEntry?, undoManager: UndoManager?) {
        guard let project, !urls.isEmpty else { return }
        var parent: UUID?
        var index: Int?
        if let target {
            if target.isGroup {
                parent = target.id
                index = target.children.count
            } else if let location = project.toc.location(of: target.id) {
                (parent, index) = location
            }
        }
        var imported: [String] = []
        // Files go into the book's folders for pages, figures and downloads (Project Settings).
        perform("Add Files", undoManager) { project in
            let result = try project.importFiles(urls, under: parent, at: index)
            imported = result.paths
            return result.change
        }
        if parent.map({ !expandedParts.contains($0) }) == true, let parent { expandedParts.insert(parent) }
        rebuildIndex()
        if let page = imported.first(where: { $0.hasSuffix(".md") }), self.project?.fileExists(page) == true { openFile(page) }
        // PDFs in the downloads folder are for reading, not figures: no SVG.
        let folders = project.folders
        for pdf in imported where pdf.lowercased().hasSuffix(".pdf")
            && (folders.downloads == folders.figures || (pdf as NSString).deletingLastPathComponent != folders.downloads) {
            makeSVG(for: pdf, undoManager: undoManager)
        }
    }

    /// Writes an SVG next to a PDF figure (with pdf2svg or pdftocairo, when installed), so the site
    /// shows it sharp; figures written as `name.*` then use the SVG on the web and the PDF in LaTeX.
    /// Nothing happens when the SVG exists or no converter is installed.
    func makeSVG(for pdf: String, undoManager: UndoManager?) {
        guard let project else { return }
        let svg = (pdf as NSString).deletingPathExtension + ".svg"
        guard !FileManager.default.fileExists(atPath: project.url(for: svg).path),
              let tool = FigureConverter.findTool(searchPath: build.searchPath) else { return }
        let source = project.url(for: pdf)
        let root = project.root
        Task {
            do {
                let data = try await FigureConverter.svg(fromPDF: source, tool: tool)
                guard self.project?.root == root, !FileManager.default.fileExists(atPath: root.appendingPathComponent(svg).path) else { return }
                perform("Make SVG", undoManager, showsNotice: false) { try $0.addFile(svg, data: data, summary: "Made \(svg) from \(pdf)") }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Switches the dark-mode rule for SVG figures on or off (one undo step); the preview restarts
    /// so the site loads the changed stylesheet.
    func setInvertsSVGFiguresInDarkMode(_ on: Bool, undoManager: UndoManager?) {
        perform(on ? "Invert SVG Figures" : "Stop Inverting SVG Figures", undoManager) { try $0.setInvertsSVGFiguresInDarkMode(on) }
        build.restartPreview()
    }

    /// Whether PDF figures can be turned into SVG on this Mac.
    var canMakeSVG: Bool { FigureConverter.findTool(searchPath: build.searchPath) != nil }

    /// Adds BibTeX files of the book that myst.yml does not list yet, so their keys work in {cite}.
    func addUnlistedBibliographies(undoManager: UndoManager? = nil) {
        guard let files = project?.unlistedBibFiles, !files.isEmpty else { return }
        perform("Add Bibliography", undoManager) { try $0.addBibliographies(files) }
        rebuildIndex()
    }

    /// What dropping files or sidebar items on the editor inserts into `page`: a {figure} for an
    /// image (just the image with `plain`), a link for a page. Images from outside are copied into
    /// images/ first.
    func editorDrop(_ items: [MystTextView.DropItem], plain: Bool, page: String, undoManager: UndoManager?) -> MystTextView.DropInsertion? {
        guard let project else { return nil }
        var images: [String] = []
        var pages: [String] = []
        var downloads: [String] = []
        var outside: [URL] = []
        var outsideDownloads: [URL] = []
        for item in items {
            switch item {
            case .file(let url):
                let kind = BookProject.importKind(of: url)
                if let inside = project.relativePath(of: url) {
                    if kind == .image { images.append(inside) }
                    if kind == .page { pages.append(inside) }
                    if kind == .other { downloads.append(inside) }
                } else if kind == .image {
                    outside.append(url)
                } else if kind == .other {
                    // Copied into the downloads folder and linked, so readers can download it.
                    outsideDownloads.append(url)
                }
            case .imageData(let data):
                let name = "pasted-" + Self.pasteStamp.string(from: Date())
                var path: String?
                perform("Paste Image", undoManager, showsNotice: false) { project in
                    let result = try project.addPastedImage(data, name: name)
                    path = result.path
                    return result.change
                }
                if let path { images.append(path) }
            case .sidebar(let payload):
                if let id = SidebarDrag.entryID(payload), let file = project.toc.entry(id: id)?.file {
                    pages.append(BookProject.normalized(file))
                } else if let path = SidebarDrag.filePath(payload) {
                    let kind = BookProject.importKind(of: URL(fileURLWithPath: path))
                    if kind == .image { images.append(path) } else if kind == .page { pages.append(path) } else if kind == .other { downloads.append(path) }
                }
            }
        }
        if !outside.isEmpty {
            var copied: [String] = []
            perform("Add Images", undoManager, showsNotice: false) { project in
                let result = try project.importFiles(outside, pdfsAreFigures: true)
                copied = result.paths
                return result.change
            }
            images += copied
        }
        if !outsideDownloads.isEmpty {
            var copied: [String] = []
            perform("Add Files", undoManager, showsNotice: false) { project in
                let result = try project.importFiles(outsideDownloads)
                copied = result.paths
                return result.change
            }
            downloads += copied
        }
        guard !images.isEmpty || !pages.isEmpty || !downloads.isEmpty else { return nil }
        for image in images where image.lowercased().hasSuffix(".pdf") { makeSVG(for: image, undoManager: undoManager) }

        var parts: [String] = []
        var selection: NSRange?
        var offset = 0
        for image in images {
            let path = BookProject.figureReference(to: image, from: page)
            let name = (image as NSString).lastPathComponent
            let stem = (name as NSString).deletingPathExtension
            let text: String
            if plain {
                text = "![\(stem)](\(path))"
            } else {
                text = ":::{figure} \(path)\n:label: fig-\(BookProject.slug(for: stem))\n:alt: \(stem)\n\nCaption.\n:::\n"
                // The caption is selected, ready to be typed over.
                if selection == nil { selection = NSRange(location: offset + (text as NSString).range(of: "Caption.").location, length: 8) }
            }
            parts.append(text)
            offset += (text as NSString).length + (plain ? 1 : 0)
        }
        for target in pages {
            let title = project.pageTitles[target] ?? (target as NSString).deletingPathExtension
            parts.append("[\(title)](\(BookProject.reference(to: target, from: page)))")
            offset += (parts.last! as NSString).length + 1
        }
        // A link to a file of the book: MyST copies the file into the site as a download.
        for file in downloads {
            parts.append("[\((file as NSString).lastPathComponent)](\(BookProject.reference(to: file, from: page)))")
            offset += (parts.last! as NSString).length + 1
        }
        let joined = plain || images.isEmpty ? parts.joined(separator: " ") : parts.joined(separator: images.count > 1 || !pages.isEmpty || !downloads.isEmpty ? "\n" : "")
        let end = NSRange(location: (joined as NSString).length, length: 0)
        let name = images.isEmpty ? "Insert Link" : (plain ? "Insert Image" : "Insert Figure")
        return MystTextView.DropInsertion(text: joined, selection: selection ?? end, actionName: name)
    }

    /// Names pasted images by date and time, e.g. pasted-2026-10-26-0814.png.
    private static let pasteStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter
    }()

    // MARK: Bibliography

    /// The entries of every BibTeX file in the book.
    func bibRecords() -> [BibRecord] {
        guard let project else { return [] }
        return project.bibFiles.flatMap { file in
            (try? String(contentsOf: project.url(for: file), encoding: .utf8)).map { BibTeX.records(in: $0, file: file) } ?? []
        }
    }

    /// Writes an edited or new entry (or removes one when `record` is nil) as one undo step.
    /// `key` is the entry's key before editing; nil for a new entry.
    @discardableResult
    func saveBibRecord(_ record: BibRecord?, replacing key: String?, in file: String, undoManager: UndoManager?) -> Bool {
        guard let project, let before = try? String(contentsOf: project.url(for: file), encoding: .utf8) else { return false }
        let records = BibTeX.records(in: before, file: file)
        if let record, record.key != key, records.contains(where: { $0.key == record.key }) {
            errorMessage = "\(file) already has an entry “\(record.key)”."
            return false
        }
        let after = BibTeX.replacing(key: key ?? record?.key ?? "", with: record, in: before, file: file)
        let action = record == nil ? "Delete Entry" : (key == nil ? "New Entry" : "Edit Entry")
        var succeeded = true
        perform(action, undoManager, showsNotice: false) { project in
            do {
                return try project.editFile(file, from: before, to: after, summary: "\(action) — \(file) updated")
            } catch {
                succeeded = false
                throw error
            }
        }
        rebuildIndex()
        return succeeded
    }

    /// The page's title and book values for filling a template.
    func templateValues(for path: String?) -> TemplateValues {
        guard let project else { return TemplateValues(title: "") }
        let title = path.flatMap { project.pageTitles[$0] } ?? ""
        let author = ProjectSettings(yaml: project.configText).authors.first?.name ?? ""
        return TemplateValues(title: title, author: author, book: project.title)
    }

    func showSnippets() {
        guard currentDocument != nil, editorTextView != nil, settingsTab == nil else { return }
        isShowingSnippets = true
    }

    /// Inserts a snippet at the cursor of the editor, as one undo step. The selection goes where the
    /// snippet says `{{selection}}`. A snippet of several lines starts on its own line and takes the
    /// indentation of the line it is inserted into.
    func insertSnippet(_ template: PageTemplate) {
        isShowingSnippets = false
        guard let textView = editorTextView, let document = currentDocument else { return }
        let range = textView.selectedRange()
        let selected = (textView.string as NSString).substring(with: range)
        let insertion = template.snippetInsertion(selection: selected, values: templateValues(for: document.path))
        (textView as? MystTextView)?.insert(insertion.text, stops: insertion.stops, replacing: range, actionName: "Insert \(template.name)")
    }

    /// Edits the current page through its editor (one undo step, like typing), e.g. from the
    /// inspector's forms. `transform` gets the page's text and returns the new text.
    func editCurrentPage(_ actionName: String, _ transform: (String) throws -> String) {
        do {
            if let textView = editorTextView as? MystTextView, textView.window != nil {
                textView.replaceText(with: try transform(textView.string), actionName: actionName)
            } else if let document = currentDocument {
                // Preview only: no editor on screen; it shows the new text when it appears.
                document.useText(try transform(document.text))
                documentEdited(document)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Puts the cursor where a new option of `block` goes, for typing one the form does not list.
    func revealDirectiveOptions(_ block: DirectiveBlock) {
        guard let textView = editorTextView else { return }
        let location = block.options.last.map { NSMaxRange($0.line) } ?? min(NSMaxRange(block.openingLine) + 1, (textView.string as NSString).length)
        textView.window?.makeFirstResponder(textView)
        (textView as? MystTextView)?.insert(block.indent + ":", selecting: NSRange(location: block.indent.count + 1, length: 0),
                                             replacing: NSRange(location: location, length: 0), actionName: "Add Option")
    }

    /// Copies the book (without `_build`) into the user's book templates.
    func saveBookAsTemplate(name: String) {
        guard let project else { return }
        saveAll()
        let target = TemplateLibrary.userBooksFolder.appendingPathComponent(name, isDirectory: true)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: target.path) else {
            errorMessage = "A book template named “\(name)” already exists."
            return
        }
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for item in try fm.contentsOfDirectory(atPath: project.root.path) where !["_build", ".git", "node_modules"].contains(item) {
                try fm.copyItem(at: project.root.appendingPathComponent(item), to: target.appendingPathComponent(item))
            }
            notice = Notice(message: "Saved book template “\(name)”", change: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Build, preview, export

    /// Pages are saved first, because MyST reads the files on disk.
    func buildBook() {
        guard let project else { return }
        saveAll()
        build.build(project.root)
    }

    /// While the preview is visible, a page is saved shortly after typing stops, so MyST
    /// rebuilds it and the preview reloads, as it does when the file is saved by another editor.
    func documentEdited(_ document: OpenDocument) {
        scheduleIndexUpdate(for: document)
        guard viewMode.showsPreview else { return }
        liveSaveTask?.cancel()
        liveSaveTask = Task { [weak self, weak document] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self, let document, document.isDirty, self.viewMode.showsPreview,
                  self.documents.contains(where: { $0 === document }) else { return }
            self.save(document)
        }
    }

    /// Find, Find Next, … in the editor. Sent to the text view directly: as a first-responder
    /// action it was not handled, and the find bar did not open.
    func performFind(_ action: NSTextFinder.Action) {
        guard let textView = editorTextView else { return }
        textView.window?.makeFirstResponder(textView)
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        textView.performTextFinderAction(sender)
    }

    // MARK: Index, completion, diagnostics

    /// Reads all pages and bibliographies in the background. Unsaved text in open tabs wins
    /// over the files on disk.
    func rebuildIndex() {
        guard let project else { return }
        if project.plugins.map(\.source) != inspectedPlugins {
            // MyST reads plugins when the preview starts; a running preview needs a restart.
            if inspectedPlugins != nil { build.pluginsChanged() }
            inspectPlugins()
        }
        let root = project.root
        let bibliography = project.config.bibliography
        indexTask?.cancel()
        indexTask = Task { [weak self] in
            let built = await Task.detached(priority: .utility) {
                ProjectIndex.build(root: root, bibliography: bibliography)
            }.value
            guard let self, !Task.isCancelled, self.project?.root == root else { return }
            var index = built
            self.applyPlugins(to: &index)
            for document in self.documents where document.isDirty {
                index.update(page: document.path, text: document.text)
            }
            self.index = index
            self.refreshDiagnostics()
        }
    }

    #if DEBUG
    /// For snapshots, which run inside a main-queue block where the background build cannot finish.
    func buildIndexNow() {
        guard let project else { return }
        index = ProjectIndex.build(root: project.root, bibliography: project.config.bibliography)
        applyPlugins(to: &index)
    }
    #endif

    /// Re-indexes a page shortly after typing stops, then updates the problems of open pages.
    private func scheduleIndexUpdate(for document: OpenDocument) {
        let path = document.path
        // myst.yml can be open as text; it is not a page.
        guard document.isPage else { return }
        indexUpdateTasks[path]?.cancel()
        indexUpdateTasks[path] = Task { [weak self, weak document] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, let document else { return }
            self.indexUpdateTasks[path] = nil
            self.index.update(page: path, text: document.text)
            self.refreshDiagnostics()
        }
    }

    func refreshDiagnostics() {
        for document in documents {
            let found = index.diagnostics(for: document.path)
            if found != document.diagnostics { document.diagnostics = found }
        }
    }

    /// Suggestions for what is typed at the cursor in `page`.
    func completions(for context: CompletionContext, page: String, textAfterCursor: String) -> [CompletionItem] {
        index.completions(for: context, page: page, textAfterCursor: textAfterCursor)
    }

    func exportZip() {
        guard let project else { return }
        saveAll()
        build.exportZip(project.root, bookTitle: project.title)
    }

    /// Builds the documents listed in `project.exports` (PDF, Word, …), then shows them in Finder.
    func buildDocuments() {
        guard let project else { return }
        saveAll()
        let exports = ProjectSettings(yaml: project.configText).exports
        // Book documents and the documents pages list themselves.
        let pageFlags = project.markdownFiles.flatMap { project.pageExports($0).buildFlags }
        var flags: [String] = []
        for flag in exports.map(\.buildFlag) + pageFlags where !flags.contains(flag) { flags.append(flag) }
        guard !flags.isEmpty else { return }
        let root = project.root
        let outputs = exports.map(\.output).filter { !$0.isEmpty }.map { root.appendingPathComponent($0) }
        build.build(root, options: BuildOptions(execute: build.executesNotebooks(root), documentFlags: flags)) { folder in
            let existing = outputs.filter { FileManager.default.fileExists(atPath: $0.path) }
            NSWorkspace.shared.activateFileViewerSelecting(existing.isEmpty ? [folder] : existing)
        }
    }

    /// Builds the HTML site with the export dialog's options; copies it to `destination` when that
    /// is not `_build/html`, and zips it when asked. Shows the result in Finder when `reveal`.
    func exportSite(options: BuildOptions, destination: URL, zip: Bool, reveal: Bool) {
        guard let project else { return }
        saveAll()
        let title = project.title
        build.build(project.root, options: options) { [weak self] output in
            Task { @MainActor in
                do {
                    var shown = destination
                    if destination.standardizedFileURL != output.standardizedFileURL {
                        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                        let copy = try await ProcessRunner.run("/usr/bin/ditto", [output.path, destination.path])
                        guard copy.exitCode == 0 else { throw BuildController.ExportError.zip(copy.lines.joined(separator: "\n")) }
                    }
                    if zip {
                        let file = destination.deletingLastPathComponent().appendingPathComponent(BookSlug.fileName(for: title) + "-html.zip")
                        try? FileManager.default.removeItem(at: file)
                        let result = try await ProcessRunner.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", destination.path, file.path])
                        guard result.exitCode == 0 else { throw BuildController.ExportError.zip(result.lines.joined(separator: "\n")) }
                        shown = file
                    }
                    if reveal { NSWorkspace.shared.activateFileViewerSelecting([shown]) }
                } catch {
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func revealBuild() {
        guard let project else { return }
        saveAll()
        build.revealOutput(project.root)
    }

    /// Opens the page a build message is about and selects its line.
    func showMessage(_ message: BuildMessage) {
        guard let file = message.file, let project, project.fileExists(file) else { return }
        let path = project.markdownFiles.first { $0 == file || $0 == file + ".md" } ?? file
        openFile(path)
        guard let document = currentDocument else { return }
        if let line = message.line {
            document.reveal(document.rangeOfLine(line))
        }
    }

    // MARK: Saving and closing

    func saveCurrent() {
        guard let document = currentDocument else { return }
        save(document)
    }

    /// Tabs whose file changed on disk are left alone until the user decides.
    func saveAll() {
        documents.filter { $0.isDirty && $0.diskConflict == nil }.forEach(save)
    }

    private func save(_ document: OpenDocument) {
        guard document.diskConflict == nil else { return }
        do {
            try document.save()
        } catch {
            errorMessage = "Could not save \(document.fileName): \(error.localizedDescription)"
            return
        }
        fileRevision += 1
        guard var project else { return }
        if document.isPage, project.markdownFiles.contains(document.path) {
            // A changed first heading changes the title shown in the sidebar.
            if project.refreshTitle(of: document.path) { self.project = project }
        } else {
            let hadProblem = project.configProblem != nil
            try? project.reload()
            self.project = project
            // A hand-edited myst.yml may list other bibliographies or plugins.
            if document.path == BookProject.configFileName {
                rebuildIndex()
                if hadProblem, project.configProblem == nil { notice = Notice(message: "myst.yml can be read again", change: nil) }
            }
        }
    }

    /// Closes a tab without saving it (its file is gone and the user chose not to save it again).
    func discard(_ document: OpenDocument) {
        guard let index = documents.firstIndex(where: { $0 === document }) else { return }
        removeTab(at: index)
    }

    /// Removes a tab; the tab after it (or the last one) becomes current if it was.
    private func removeTab(at index: Int) {
        let path = documents.remove(at: index).path
        if currentPath == path {
            currentPath = documents.indices.contains(index) ? documents[index].path : documents.last?.path
        }
    }

    /// Closing a tab saves it; there is no "discard changes" in the skeleton.
    func close(_ path: String) {
        guard let index = documents.firstIndex(where: { $0.path == path }) else { return }
        if documents[index].diskConflict != nil, documents[index].isDirty {
            currentPath = path
            errorMessage = "\(documents[index].fileName) was changed on disk while it had unsaved edits. Choose “Keep My Version” or “Use Version on Disk” above the editor first."
            return
        }
        if documents[index].isDirty { save(documents[index]) }
        removeTab(at: index)
    }

    // MARK: Structural changes (always update myst.yml)

    func presentNewChapter(in part: UUID?) {
        newChapterPart = part
        isShowingNewChapter = true
    }

    func addChapter(title: String, in part: UUID?, template: PageTemplate? = nil, undoManager: UndoManager?) {
        var path: String?
        perform("New Chapter", undoManager) { project in
            var exports: PageExports?
            // A new page gets the formats every page already has.
            let shared = ProjectSettings.exportFormats.filter { coverage(of: $0) == .all }
            if pageExportsEnabled, !shared.isEmpty {
                exports = PageExports()
                exports?.formats = shared
            }
            let result = try project.addPage(title: title, under: part, template: template, exports: exports)
            path = result.path
            return result.change
        }
        if let part { expandedParts.insert(part) }
        if let path { openFile(path) }
    }

    func addPart(title: String, undoManager: UndoManager?) {
        perform("New Part", undoManager) { try $0.addPart(title: title) }
    }

    func addToBook(_ path: String, in part: UUID?, undoManager: UndoManager?) {
        perform("Add to Book", undoManager) { try $0.addExistingFile(path, under: part) }
    }

    func move(_ id: UUID, toParent parent: UUID?, at index: Int, undoManager: UndoManager?) {
        perform("Move", undoManager) { try $0.moveEntry(id, toParent: parent, at: index) }
    }

    func move(_ id: UUID, by offset: Int, undoManager: UndoManager?) {
        perform(offset < 0 ? "Move Up" : "Move Down", undoManager) { try $0.moveEntry(id, by: offset) }
    }

    func removeFromBook(_ id: UUID, undoManager: UndoManager?) {
        perform("Remove from Book", undoManager) { try $0.removeEntry(id) }
    }

    /// Removes the selected page from the table of contents (Delete key). The file stays.
    func removeSelectedFromBook(undoManager: UndoManager?) {
        guard let path = currentPath, let project,
              let entry = project.entries(forFile: path).first else { return }
        removeFromBook(entry.id, undoManager: undoManager)
    }

    func moveToTrash(_ path: String, undoManager: UndoManager?) {
        perform("Move to Trash", undoManager) { try $0.trashPage(path) }
    }

    func renamePart(_ id: UUID, to title: String, undoManager: UndoManager?) {
        perform("Rename Part", undoManager) { try $0.renamePart(id, to: title) }
    }

    func renamePage(_ path: String, title: String, newPath: String, undoManager: UndoManager?) {
        perform("Rename", undoManager) { try $0.renamePage(path, title: title, newPath: newPath).change }
    }

    /// Handles items dragged onto a sidebar row: TOC entries move, loose files are added.
    /// Dropping on a part puts the items at its end; dropping on a page puts them before it.
    @discardableResult
    func drop(_ items: [String], onto target: TOCEntry, undoManager: UndoManager?) -> Bool {
        guard let project else { return false }
        for item in items {
            let parent: UUID?
            let index: Int
            if target.isGroup {
                parent = target.id
                index = target.children.count
            } else if let location = self.project?.toc.location(of: target.id) {
                (parent, index) = location
            } else {
                return false
            }
            if let id = SidebarDrag.entryID(item) {
                guard id != target.id else { continue }
                move(id, toParent: parent, at: index, undoManager: undoManager)
            } else if let path = SidebarDrag.filePath(item), project.filesNotInTOC.contains(path) {
                perform("Add to Book", undoManager) { try $0.addExistingFile(path, under: parent, at: index) }
            }
        }
        return true
    }

    func revert(_ change: StructuralChange) {
        undo(change, actionName: "", undoManager: nil)
    }

    /// Runs a structural operation on the project: saves open pages first, so the operation
    /// sees what is on screen, then updates tabs and registers undo.
    func perform(_ actionName: String, _ undoManager: UndoManager?, showsNotice: Bool = true, _ operation: (inout BookProject) throws -> StructuralChange?) {
        saveAll()
        guard var project else { return }
        do {
            let change = try operation(&project)
            self.project = project
            guard let change else { return }
            fileRevision += 1
            refreshDocuments(after: change)
            rebuildIndex()
            if showsNotice { notice = Notice(message: change.summary, change: change) }
            registerUndo(of: change, actionName: actionName, undoManager: undoManager)
        } catch {
            self.project = project // an operation may have reloaded the book
            errorMessage = error.localizedDescription
        }
    }

    /// Reverts `change`. Called by the undo manager for both undo and redo:
    /// the inverse it registers lands on the other stack.
    private func undo(_ change: StructuralChange, actionName: String, undoManager: UndoManager?) {
        saveAll()
        guard var project else { return }
        let isRedo = undoManager?.isRedoing == true
        do {
            let inverse = try project.revert(change)
            self.project = project
            fileRevision += 1
            refreshDocuments(after: inverse)
            rebuildIndex()
            let what = change.changesConfig ? " — myst.yml updated" : ""
            notice = Notice(message: (isRedo ? "Redone" : "Undone") + what, change: nil)
            registerUndo(of: inverse, actionName: actionName, undoManager: undoManager)
        } catch {
            self.project = project
            errorMessage = error.localizedDescription
        }
    }

    private func registerUndo(of change: StructuralChange, actionName: String, undoManager: UndoManager?) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { [weak undoManager] store in
            // Undo and redo run on the main thread, from the Edit menu or ⌘Z.
            MainActor.assumeIsolated { store.undo(change, actionName: actionName, undoManager: undoManager) }
        }
        undoManager.setActionName(actionName)
    }

    /// After a change: follow moved files, close tabs of removed ones, and reload pages whose
    /// links were rewritten. All documents were saved before the change, so nothing is lost.
    private func refreshDocuments(after change: StructuralChange) {
        guard let project else { return }
        var moves: [String: String] = [:]
        for move in change.moves {
            if let from = project.relativePath(of: move.from), let to = project.relativePath(of: move.to) {
                moves[from] = to
            }
        }
        var refreshed: [OpenDocument] = []
        var current = currentPath
        for document in documents {
            if let newPath = moves[document.path] {
                if let moved = try? makeDocument(newPath, root: project.root) {
                    refreshed.append(moved)
                    if current == document.path { current = newPath }
                }
                continue
            }
            guard FileManager.default.fileExists(atPath: document.url.path) else { continue }
            document.reloadFromDisk()
            refreshed.append(document)
        }
        documents = refreshed
        if let current, refreshed.contains(where: { $0.path == current }) {
            currentPath = current
        } else {
            currentPath = refreshed.last?.path
        }
    }
}

/// Drag payloads in the sidebar: a TOC entry ("toc:<id>") or a file not in the TOC ("file:<path>").
enum SidebarDrag {
    static func entry(_ id: UUID) -> String { "toc:" + id.uuidString }
    static func file(_ path: String) -> String { "file:" + path }

    static func entryID(_ item: String) -> UUID? {
        item.hasPrefix("toc:") ? UUID(uuidString: String(item.dropFirst(4))) : nil
    }

    static func filePath(_ item: String) -> String? {
        item.hasPrefix("file:") ? String(item.dropFirst(5)) : nil
    }
}
