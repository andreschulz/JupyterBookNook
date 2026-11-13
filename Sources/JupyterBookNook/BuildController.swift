import AppKit
import BuildService
import Foundation
import Observation

/// Builds, previews and the toolchain for the open book. The editor's own features never need
/// MyST; it is used only here, for `myst build --html` and the live preview (`myst start`).
@MainActor
@Observable
final class BuildController {
    enum BuildState: Equatable {
        case idle
        case running(started: Date)
        case finished(succeeded: Bool, duration: TimeInterval)
        case failed(String)
    }

    enum ManagedState: Equatable {
        case idle
        case installing(String, fraction: Double?)
        case failed(String)
    }

    // MARK: Toolchains

    private(set) var searchPath: [String] = ToolchainLocator.commonDirectories
    private(set) var candidates: [Toolchain] = []
    private(set) var versions: [Toolchain: String] = [:]
    private(set) var isDetecting = true
    let managed = ManagedToolchain()
    private(set) var managedState: ManagedState = .idle
    /// Whether the managed copy exists; kept here so views refresh after install and removal.
    private(set) var isManagedInstalled = ManagedToolchain().isInstalled

    var defaultChoice: ToolchainChoice {
        didSet {
            Self.save(defaultChoice, key: Self.defaultKey)
            toolchainChanged()
        }
    }
    private var bookChoices: [String: ToolchainChoice] {
        didSet {
            Self.save(bookChoices, key: Self.booksKey)
            toolchainChanged()
        }
    }
    /// Books whose notebooks are run when building and in the preview (`--execute`).
    private var executingBooks: Set<String> {
        didSet {
            Self.save(executingBooks, key: Self.executeKey)
            toolchainChanged()
        }
    }

    // MARK: Build and preview

    private(set) var buildState: BuildState = .idle
    private(set) var buildLog: [String] = []
    private(set) var buildMessages: [BuildMessage] = []
    private(set) var lastOutputFolder: URL?
    /// Pages MyST reported as built during the current build ("📖 Built intro.md").
    private(set) var builtPages = 0
    var isShowingPanel = false
    var panelTab: PanelTab = .problems

    enum PanelTab: String, CaseIterable {
        case problems = "Problems"
        case log = "Log"
    }

    let previewServer = PreviewServer()
    private(set) var previewState: PreviewServer.State = .stopped
    private(set) var previewMessages: [BuildMessage] = []
    var isShowingSetup = false

    private var buildTask: Task<Void, Never>?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?

    init() {
        defaultChoice = Self.load(ToolchainChoice.self, key: Self.defaultKey) ?? .automatic
        bookChoices = Self.load([String: ToolchainChoice].self, key: Self.booksKey) ?? [:]
        executingBooks = Self.load(Set<String>.self, key: Self.executeKey) ?? []
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [previewServer] _ in
            previewServer.stopNow()
        }
        Task { await detectToolchains() }
    }

    func detectToolchains(for root: URL? = nil) async {
        isDetecting = true
        searchPath = await ToolchainLocator.defaultSearchPath()
        let locator = self.locator
        candidates = locator.candidates(for: root ?? currentRoot)
        isDetecting = false
        let searchPath = searchPath
        for toolchain in candidates where versions[toolchain] == nil {
            if let version = await toolchain.version(searchPath: searchPath) { versions[toolchain] = version }
        }
    }

    var locator: ToolchainLocator {
        ToolchainLocator(searchPath: searchPath, managedToolchain: managed.isInstalled ? managed.toolchain : nil)
    }

    /// The book whose toolchain choice and builds this controller manages.
    var currentRoot: URL?

    func choice(for root: URL?) -> ToolchainChoice? {
        root.flatMap { bookChoices[$0.standardizedFileURL.path] }
    }

    func setChoice(_ choice: ToolchainChoice?, for root: URL) {
        bookChoices[root.standardizedFileURL.path] = choice
    }

    func executesNotebooks(_ root: URL?) -> Bool {
        root.map { executingBooks.contains($0.standardizedFileURL.path) } ?? false
    }

    func setExecutesNotebooks(_ execute: Bool, for root: URL) {
        let key = root.standardizedFileURL.path
        if execute { executingBooks.insert(key) } else { executingBooks.remove(key) }
    }

    /// The toolchain the open book uses: its own choice, else the default.
    func toolchain(for root: URL?) -> Toolchain? {
        locator.resolve(choice(for: root) ?? defaultChoice, for: root)
    }

    // MARK: Building

    var isBuilding: Bool {
        if case .running = buildState { return true }
        return false
    }

    /// Runs `build --html` (or the document exports in `options`). `then` runs on success, e.g. to
    /// export the result. Without `options`, the book's notebook setting applies.
    func build(_ root: URL, options: BuildOptions? = nil, then: ((URL) -> Void)? = nil) {
        guard !isBuilding else { return }
        guard let toolchain = toolchain(for: root) else {
            isShowingSetup = true
            return
        }
        buildState = .running(started: Date())
        buildLog = []
        buildMessages = []
        builtPages = 0
        isShowingPanel = true
        let searchPath = searchPath
        let options = options ?? BuildOptions(execute: executesNotebooks(root))
        buildTask = Task {
            do {
                let result = try await BuildRunner.buildHTML(projectRoot: root, toolchain: toolchain, searchPath: searchPath, options: options) { line in
                    Task { @MainActor [weak self] in
                        self?.buildLog.append(line)
                        if line.contains("Built "), line.contains(".md") || line.contains(".ipynb") { self?.builtPages += 1 }
                    }
                }
                if Task.isCancelled {
                    buildState = .failed("Cancelled")
                    return
                }
                buildLog = result.log
                buildMessages = result.messages
                lastOutputFolder = result.outputFolder
                buildState = .finished(succeeded: result.succeeded, duration: result.duration)
                panelTab = result.succeeded && result.messages.isEmpty ? panelTab : (result.messages.isEmpty ? .log : .problems)
                if result.succeeded { then?(result.outputFolder) }
            } catch {
                buildState = .failed(error.localizedDescription)
                panelTab = .log
            }
        }
    }

    /// Stops a running build; it ends as failed with "Cancelled".
    func cancelBuild() {
        guard isBuilding else { return }
        buildTask?.cancel()
    }

    // MARK: Preview
    //
    // `myst start` runs for as long as a book is open, so switching to Split or Preview is
    // instant and MyST keeps the site current. The site reloads itself (over MyST's WebSocket)
    // whenever a page is written; the store saves pages shortly after typing while the preview
    // is visible.

    /// Starts the preview server for `root` unless it is already running or starting.
    /// Asks for a MyST installation only when `askIfMissing` (the user wants to see the preview).
    func ensurePreview(_ root: URL, askIfMissing: Bool = false) {
        switch previewServer.state {
        case .starting, .running: return
        case .stopped, .failed: break
        }
        startPreview(root, askIfMissing: askIfMissing)
    }

    func startPreview(_ root: URL, askIfMissing: Bool = true) {
        guard let toolchain = toolchain(for: root) else {
            if askIfMissing { isShowingSetup = true }
            return
        }
        do {
            try previewServer.start(projectRoot: root, toolchain: toolchain, searchPath: searchPath, execute: executesNotebooks(root)) { [weak self] in
                Task { @MainActor in self?.syncPreview() }
            }
        } catch {
            previewState = .failed(error.localizedDescription)
        }
        syncPreview()
    }

    func stopPreview() {
        previewServer.stop()
        syncPreview()
    }

    func restartPreview() {
        guard let root = currentRoot else { return }
        previewServer.stop()
        startPreview(root)
    }

    /// The book's plugins or a plugin file changed: MyST loads plugins only when it starts, so a
    /// running preview is restarted.
    /// Waits a moment, so saving a plugin while typing restarts it once.
    func pluginsChanged() {
        pluginRestart?.cancel()
        pluginRestart = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.toolchainChanged()
        }
    }
    @ObservationIgnored private var pluginRestart: Task<Void, Never>?

    /// A different MyST was chosen or installed: restart the running preview with it.
    private func toolchainChanged() {
        guard let root = currentRoot, previewServer.state != .stopped else { return }
        previewServer.stop()
        startPreview(root, askIfMissing: false)
    }

    var isPreviewActive: Bool { previewState != .stopped }

    private func syncPreview() {
        previewState = previewServer.state
        previewMessages = previewServer.messages
    }

    var previewURL: URL? {
        if case .running(let url) = previewState { return url }
        return nil
    }

    var previewLog: [String] { previewServer.recentLog }
    var previewContentPort: Int? { previewServer.contentPort }

    // MARK: Stylesheet in the preview

    /// Counts stylesheet swaps; the preview's web view reloads its stylesheets when it changes.
    /// MyST's live refresh updates the page content only, so a changed stylesheet needs this.
    private(set) var previewStyleRevision = 0
    private(set) var isUpdatingPreviewStyle = false
    /// Counts full reloads of the preview asked for by the app (site settings such as the site
    /// name or footer, which the in-place refresh does not show).
    private(set) var previewReloadRevision = 0
    @ObservationIgnored private var reloadWait: Task<Void, Never>?

    /// Reloads the preview after MyST has had time to rebuild the site for a changed myst.yml.
    func reloadPreviewSoon() {
        guard previewURL != nil else { return }
        reloadWait?.cancel()
        isUpdatingPreviewStyle = true
        reloadWait = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            self.previewReloadRevision += 1
            self.isUpdatingPreviewStyle = false
        }
    }
    @ObservationIgnored private var styleWait: Task<Void, Never>?

    /// Waits until the preview server serves `css` (MyST rebuilds it shortly after the file
    /// changes), then swaps the stylesheet in the preview. Gives up after 20 seconds and swaps anyway.
    func updatePreviewStyle(expecting css: String) {
        guard let base = previewURL, let url = URL(string: "/myst-theme.css", relativeTo: base) else { return }
        let expected = css.trimmingCharacters(in: .whitespacesAndNewlines)
        styleWait?.cancel()
        isUpdatingPreviewStyle = true
        styleWait = Task { [weak self] in
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            for _ in 0..<80 {
                if let (data, _) = try? await URLSession.shared.data(for: request),
                   String(decoding: data, as: UTF8.self).contains(expected) { break }
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
            }
            guard let self, !Task.isCancelled else { return }
            self.previewStyleRevision += 1
            self.isUpdatingPreviewStyle = false
        }
    }

    /// MyST's page URLs, read from the site it wrote; refreshed when the preview starts.
    @ObservationIgnored private var siteSlugs: [String: String] = [:]
    @ObservationIgnored private var siteSlugsLoaded: Date?

    /// The preview URL of `page` (project-relative), using MyST's own mapping where it exists.
    func previewURL(for page: String?, pages: [String], root: URL) -> URL? {
        guard let base = previewURL else { return nil }
        guard let page else { return base }
        // MyST rewrites the site content as pages change; re-read it at most every few seconds.
        if siteSlugsLoaded.map({ Date().timeIntervalSince($0) > 3 }) ?? true || siteSlugs[page] == nil {
            siteSlugs = MystSlugs.fromSite(projectRoot: root)
            siteSlugsLoaded = Date()
        }
        let slug = siteSlugs[page] ?? MystSlugs.computed(pages: pages)[page]
        guard let slug else { return base }
        return URL(string: MystSlugs.path(for: slug), relativeTo: base)?.absoluteURL ?? base
    }

    /// Stops everything that belongs to the previous book.
    func bookChanged(to root: URL?) {
        stopPreview()
        buildTask?.cancel()
        buildState = .idle
        buildLog = []
        buildMessages = []
        lastOutputFolder = nil
        isShowingPanel = false
        currentRoot = root
        Task {
            await detectToolchains(for: root)
            if let root, currentRoot == root { ensurePreview(root) }
        }
    }

    // MARK: Managed toolchain

    func installManaged() {
        guard case .idle = managedState else {
            if case .failed = managedState { managedState = .idle } else { return }
            installManaged()
            return
        }
        managedState = .installing("Preparing…", fraction: nil)
        Task {
            do {
                try await managed.install { step in
                    Task { @MainActor [weak self] in self?.managedState = Self.describe(step) }
                }
                managedState = .idle
                isManagedInstalled = managed.isInstalled
                await detectToolchains()
                if let root = currentRoot { ensurePreview(root) }
            } catch {
                managedState = .failed(error.localizedDescription)
            }
        }
    }

    func removeManaged() {
        do {
            try managed.remove()
            if defaultChoice == .managed { defaultChoice = .automatic }
            isManagedInstalled = managed.isInstalled
        } catch {
            managedState = .failed(error.localizedDescription)
        }
        Task { await detectToolchains() }
    }

    private static func describe(_ step: ManagedToolchain.Step) -> ManagedState {
        switch step {
        case .downloadingNode(let fraction): return .installing("Downloading Node.js \(ManagedToolchain.nodeVersion)…", fraction: fraction)
        case .verifying: return .installing("Checking the download…", fraction: nil)
        case .unpacking: return .installing("Unpacking Node.js…", fraction: nil)
        case .installingMyst: return .installing("Installing MyST \(ManagedToolchain.mystVersion)…", fraction: nil)
        case .done: return .idle
        }
    }

    // MARK: Export

    /// Builds, then writes `_build/html` as a zip file chosen in a save panel.
    func exportZip(_ root: URL, bookTitle: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = BookSlug.fileName(for: bookTitle) + "-html.zip"
        panel.allowedContentTypes = [.zip]
        panel.message = "The book is built first, then its HTML is saved as a zip file."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        build(root) { [weak self] output in
            Task { @MainActor in
                do {
                    try? FileManager.default.removeItem(at: destination)
                    let zip = try await ProcessRunner.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", output.path, destination.path])
                    guard zip.exitCode == 0 else { throw ExportError.zip(zip.lines.joined(separator: "\n")) }
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                } catch {
                    self?.buildState = .failed(error.localizedDescription)
                }
            }
        }
    }

    func revealOutput(_ root: URL) {
        let folder = lastOutputFolder ?? root.appendingPathComponent("_build/html")
        if FileManager.default.fileExists(atPath: folder.path) {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } else {
            build(root) { output in NSWorkspace.shared.activateFileViewerSelecting([output]) }
        }
    }

    enum ExportError: LocalizedError {
        case zip(String)
        var errorDescription: String? {
            if case .zip(let log) = self { return "Creating the zip file failed.\n\(log)" }
            return nil
        }
    }

    // MARK: Persistence

    private static let defaultKey = "toolchain.default"
    private static let booksKey = "toolchain.books"
    private static let executeKey = "execute.books"

    private static func save<T: Encodable>(_ value: T, key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}

/// File names derived from a book title.
enum BookSlug {
    static func fileName(for text: String) -> String {
        var slug = ""
        for scalar in text.lowercased().unicodeScalars {
            if scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
            } else if !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "book" : trimmed
    }
}
