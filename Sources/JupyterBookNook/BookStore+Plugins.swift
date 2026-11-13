import AppKit
import BookModel
import BuildService
import Foundation
import MystSyntax
import ProjectIndex

/// What the app knows about one plugin.
enum PluginStatus: Equatable {
    case reading
    case read(PluginSpec)
    case failed(String)
    /// Executable plugins (Python and others) are only run by MyST; what they add is not known.
    case executable
}

/// Plugins of the open book (Plugins screen): listed under `project.plugins` in myst.yml.
extension BookStore {
    /// The plugins in myst.yml, then the switched-off ones.
    var allPlugins: [(entry: PluginEntry, isEnabled: Bool)] {
        let enabled = project?.plugins ?? []
        let enabledSources = Set(enabled.map(\.source))
        return enabled.map { ($0, true) } + disabledPlugins.filter { !enabledSources.contains($0.source) }.map { ($0, false) }
    }

    /// Where plugins given as URLs are downloaded to, to read what they add.
    static var pluginCache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JupyterBookNook/plugins", isDirectory: true)
    }

    /// Reads what every plugin adds, with Node.js when it is found (the toolchain's folders, then
    /// the search path), and updates completion and problems when done. URLs are downloaded once;
    /// `reload` downloads them again.
    func inspectPlugins(reload: Bool = false) {
        guard let project else { return }
        let root = project.root
        let entries = allPlugins.map(\.entry)
        inspectedPlugins = project.plugins.map(\.source)
        for entry in entries {
            pluginStatus[entry.source] = entry.isExecutable ? .executable : .reading
        }
        pluginStatus = pluginStatus.filter { source, _ in entries.contains { $0.source == source } }
        applyPluginsToIndex()
        let searchPath = (build.toolchain(for: root)?.pathDirectories ?? []) + build.searchPath
        let node = PluginInspector.findNode(in: searchPath)
        pluginTask?.cancel()
        pluginTask = Task { [weak self] in
            for entry in entries where !entry.isExecutable {
                let status: PluginStatus
                do {
                    let file = try await Self.localFile(for: entry, root: root, reload: reload)
                    switch await PluginInspector.inspect(file: file, node: node, searchPath: searchPath) {
                    case .success(let spec): status = .read(spec)
                    case .failure(let error): status = .failed(error.localizedDescription)
                    }
                } catch {
                    status = .failed(error.localizedDescription)
                }
                guard let self, !Task.isCancelled, self.project?.root == root else { return }
                self.pluginStatus[entry.source] = status
            }
            guard let self, !Task.isCancelled else { return }
            self.applyPluginsToIndex()
        }
    }

    private static func localFile(for entry: PluginEntry, root: URL, reload: Bool) async throws -> URL {
        guard entry.isURL else {
            let file = root.appendingPathComponent(BookProject.normalized(entry.source))
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw PluginInspectorError.failed("The file \(entry.source) does not exist.")
            }
            return file
        }
        guard let url = URL(string: entry.source) else { throw PluginInspectorError.failed("This is not a valid URL.") }
        let cached = PluginInspector.cacheFile(for: url, in: pluginCache)
        if !reload, FileManager.default.fileExists(atPath: cached.path) { return cached }
        return try await PluginInspector.download(url, into: pluginCache)
    }

    /// Gives the index the names the plugins add.
    func applyPluginsToIndex() {
        applyPlugins(to: &index)
        refreshDiagnostics()
    }

    func applyPlugins(to index: inout ProjectIndex) {
        guard let project else { return }
        var directives: [MystCatalog.Entry] = []
        var roles: [MystCatalog.Entry] = []
        var unread = false
        for entry in project.plugins {
            guard case .read(let spec)? = pluginStatus[entry.source] else {
                unread = true
                continue
            }
            let from = "plugin " + (spec.name ?? entry.fileName)
            func entries(_ item: PluginSpec.Item) -> [MystCatalog.Entry] {
                let summary = item.doc.map { "\($0) (\(from))" } ?? "From the \(from)"
                return ([item.name] + item.aliases).map { MystCatalog.Entry(name: $0, summary: summary, options: item.options) }
            }
            directives += spec.directives.flatMap(entries)
            roles += spec.roles.flatMap(entries)
        }
        index.pluginDirectives = directives
        index.pluginRoles = roles
        index.hasUnreadPlugins = unread
    }

    // MARK: Changing the list

    /// Adds a plugin file: one in the book is listed where it is, one from outside is copied into
    /// the book's plugins folder first.
    func addPluginFile(_ url: URL, undoManager: UndoManager?) {
        guard let project else { return }
        if let inside = project.relativePath(of: url) {
            guard !project.plugins.contains(where: { BookProject.normalized($0.source) == inside }) else {
                errorMessage = "\(inside) is already a plugin of this book."
                return
            }
            perform("Add Plugin", undoManager) { try $0.setPlugins($0.plugins + [.javascript(inside)], summary: "Added the plugin \(inside)") }
        } else {
            perform("Add Plugin", undoManager) { try $0.addPluginFile(copying: url).change }
        }
    }

    /// Adds a plugin by URL. The caller has asked for confirmation: MyST downloads and runs it.
    func addPluginURL(_ address: String, undoManager: UndoManager?) {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let project, !project.plugins.contains(where: { $0.source == address }) else { return }
        perform("Add Plugin", undoManager) { try $0.setPlugins($0.plugins + [.javascript(address)], summary: "Added the plugin \(address)") }
    }

    /// Creates a starter plugin in the book's plugins folder, adds it and opens it.
    func createPlugin(named name: String, undoManager: UndoManager?) {
        var path: String?
        perform("New Plugin", undoManager) { project in
            let result = try project.addNewPlugin(named: name)
            path = result.path
            return result.change
        }
        if let path { openFile(path) }
    }

    func removePlugin(_ entry: PluginEntry, undoManager: UndoManager?) {
        if let index = disabledPlugins.firstIndex(of: entry) {
            disabledPlugins.remove(at: index)
            pluginStatus[entry.source] = nil
            return
        }
        perform("Remove Plugin", undoManager) {
            try $0.setPlugins($0.plugins.filter { $0 != entry }, summary: "Removed the plugin \(entry.source)")
        }
    }

    /// Switching a plugin off takes it out of myst.yml (MyST has no switch) and keeps it in the
    /// app's settings for this book; switching it on puts it back at the end.
    func setPlugin(_ entry: PluginEntry, enabled: Bool, undoManager: UndoManager?) {
        guard let project else { return }
        if enabled {
            perform("Switch On Plugin", undoManager) { try $0.setPlugins($0.plugins + [entry], summary: "Switched on \(entry.fileName)") }
            if self.project?.plugins.contains(entry) == true { disabledPlugins.removeAll { $0 == entry } }
        } else {
            guard project.plugins.contains(entry) else { return }
            perform("Switch Off Plugin", undoManager) {
                try $0.setPlugins($0.plugins.filter { $0 != entry }, summary: "Switched off \(entry.fileName)")
            }
            if self.project?.plugins.contains(entry) == false, !disabledPlugins.contains(entry) { disabledPlugins.append(entry) }
        }
    }

    /// Opens a plugin's file in the editor (local files), or in the browser (URLs).
    func openPlugin(_ entry: PluginEntry) {
        guard let project else { return }
        if entry.isURL {
            if let url = URL(string: entry.source) { NSWorkspace.shared.open(url) }
        } else {
            // Not `project.fileExists`: that only knows the book's Markdown files.
            let path = BookProject.normalized(entry.source)
            guard FileManager.default.fileExists(atPath: project.url(for: path).path) else {
                errorMessage = "The file \(entry.source) does not exist."
                return
            }
            openFile(path)
        }
    }
}

/// The plugin library (Settings › Plugins): plugins for all books, added to a book from there,
/// and from a book to it.
extension BookStore {
    /// Re-reads the library folder and what its plugins add. Plugins read before are not read
    /// again unless `reload`.
    func reloadPluginLibrary(reload: Bool = false) {
        pluginLibrary = PluginLibrary.plugins()
        let ids = Set(pluginLibrary.map(\.id))
        libraryStatus = libraryStatus.filter { ids.contains($0.key) && !reload }
        let pending = pluginLibrary.filter { libraryStatus[$0.id] == nil }
        guard !pending.isEmpty else { return }
        for plugin in pending { libraryStatus[plugin.id] = .reading }
        let searchPath = (project.flatMap { build.toolchain(for: $0.root)?.pathDirectories } ?? []) + build.searchPath
        let node = PluginInspector.findNode(in: searchPath)
        libraryTask?.cancel()
        libraryTask = Task { [weak self] in
            for plugin in pending {
                let status: PluginStatus
                do {
                    let file: URL
                    switch plugin.source {
                    case .file(let url):
                        file = url
                    case .url(let address):
                        guard let url = URL(string: address) else { throw PluginInspectorError.failed("This is not a valid URL.") }
                        let cached = PluginInspector.cacheFile(for: url, in: Self.pluginCache)
                        file = !reload && FileManager.default.fileExists(atPath: cached.path)
                            ? cached : try await PluginInspector.download(url, into: Self.pluginCache)
                    }
                    switch await PluginInspector.inspect(file: file, node: node, searchPath: searchPath) {
                    case .success(let spec): status = .read(spec)
                    case .failure(let error): status = .failed(error.localizedDescription)
                    }
                } catch {
                    status = .failed(error.localizedDescription)
                }
                guard let self, !Task.isCancelled else { return }
                self.libraryStatus[plugin.id] = status
            }
        }
    }

    func addToLibrary(file url: URL) {
        libraryChange { try PluginLibrary.add(file: url) }
    }

    func addToLibrary(url address: String) {
        libraryChange { try PluginLibrary.add(url: address) }
    }

    /// Copies a plugin of the open book into the library (or keeps its URL there).
    func addToLibrary(_ entry: PluginEntry) {
        guard let project else { return }
        let added = libraryChange {
            entry.isURL ? try PluginLibrary.add(url: entry.source)
                : try PluginLibrary.add(file: project.url(for: BookProject.normalized(entry.source)))
        }
        if added { notice = Notice(message: "Added \(entry.fileName) to your plugin library", change: nil) }
    }

    func removeFromLibrary(_ plugin: LibraryPlugin) {
        libraryChange { try PluginLibrary.remove(plugin) }
    }

    func isInLibrary(_ entry: PluginEntry) -> Bool {
        guard let project else { return false }
        _ = pluginLibrary // re-evaluated when the library changes
        return PluginLibrary.contains(entry, projectRoot: project.root)
    }

    /// Whether the open book already uses this library plugin (on or off): the same URL, or a
    /// plugin file with the same contents.
    func bookHasLibraryPlugin(_ plugin: LibraryPlugin) -> Bool {
        guard let project else { return false }
        switch plugin.source {
        case .url(let address):
            return allPlugins.contains { $0.entry.source == address }
        case .file(let url):
            guard let data = try? Data(contentsOf: url) else { return false }
            return allPlugins.contains { plugin in
                !plugin.entry.isURL && (try? Data(contentsOf: project.url(for: BookProject.normalized(plugin.entry.source)))) == data
            }
        }
    }

    /// Adds a library plugin to the open book: files are copied into its plugins folder.
    func addLibraryPlugin(_ plugin: LibraryPlugin, undoManager: UndoManager?) {
        guard !bookHasLibraryPlugin(plugin) else { return }
        switch plugin.source {
        case .file(let url): addPluginFile(url, undoManager: undoManager)
        case .url(let address): addPluginURL(address, undoManager: undoManager)
        }
    }

    @discardableResult
    private func libraryChange(_ change: () throws -> Void) -> Bool {
        defer { reloadPluginLibrary() }
        do {
            try change()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
