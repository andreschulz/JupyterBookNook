import AppKit
import BookModel
import BuildService
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Plugins: the plugin library, for all books. Plugins are added to a book from here
/// or from the book's Plugins screen, and a book's plugins can be kept here.
struct PluginLibraryView: View {
    @Environment(BookStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    @State private var isAddingURL = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Plugins kept here can be added to any book. Adding one copies the file into the book's plugins folder, so the book still builds on other computers.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if store.pluginLibrary.isEmpty {
                ContentUnavailableView {
                    Label("No plugins in your library", systemImage: "puzzlepiece.extension")
                } description: {
                    Text("Add plugin files or URLs here, or use “Add to Your Plugin Library” on a plugin in a book's Plugins screen.")
                } actions: {
                    HStack {
                        Button("Add File…") { chooseFiles() }
                        Button("Add from URL…") { isAddingURL = true }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(store.pluginLibrary) { plugin in
                            LibraryPluginCard(plugin: plugin)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button("Add File…") { chooseFiles() }
                Button("Add from URL…") { isAddingURL = true }
                Button("Read Again") { store.reloadPluginLibrary(reload: true) }
                    .disabled(store.pluginLibrary.isEmpty)
                Spacer()
                Button("Show in Finder") {
                    try? FileManager.default.createDirectory(at: PluginLibrary.folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([PluginLibrary.folder])
                }
                .help(PluginLibrary.folder.path)
            }
        }
        .padding(20)
        .onAppear { store.reloadPluginLibrary() }
        .sheet(isPresented: $isAddingURL) { AddPluginURLSheet { store.addToLibrary(url: $0) } }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.message = "Choose MyST plugins (.mjs or .js) to keep in your library. They are copied."
        panel.allowedContentTypes = PluginLibrary.fileExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { store.addToLibrary(file: url) }
    }
}

/// One library plugin: what it adds, and adding it to the open book.
struct LibraryPluginCard: View {
    @Environment(BookStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    let plugin: LibraryPlugin

    var body: some View {
        let status = store.libraryStatus[plugin.id]
        let spec: PluginSpec? = if case .read(let spec)? = status { spec } else { nil }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: plugin.isURL ? "globe" : "doc.text")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec?.name ?? plugin.name).font(.headline)
                    Text(plugin.isURL ? plugin.id : plugin.name)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                if let project = store.project {
                    let has = store.bookHasLibraryPlugin(plugin)
                    Button(has ? "In “\(project.title)”" : "Add to “\(project.title)”") {
                        store.addLibraryPlugin(plugin, undoManager: undoManager)
                    }
                    .disabled(has)
                    .help(has ? "The open book already has this plugin" : "Copies the plugin into the open book and lists it in myst.yml")
                }
                Menu {
                    switch plugin.source {
                    case .file(let url):
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        Button("Open with Default App") { NSWorkspace.shared.open(url) }
                    case .url(let address):
                        Button("Open in Browser") { if let url = URL(string: address) { NSWorkspace.shared.open(url) } }
                    }
                    Divider()
                    Button("Remove from Library", role: .destructive) { store.removeFromLibrary(plugin) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            PluginDetails(status: status, isExecutable: false)
                .padding(.leading, 34)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
    }
}
