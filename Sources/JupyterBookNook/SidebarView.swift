import BookModel
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(BookStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    let project: BookProject
    /// The row a drag is currently over: a part is highlighted, a page shows an insertion line.
    @State private var dropTarget: UUID?

    private static let settingsTag = "nook:settings"
    private static let bibliographyTag = "nook:bibliography"
    private static let pluginsTag = "nook:plugins"
    private static let styleTag = "nook:style"

    private var selection: Binding<String?> {
        Binding(
            get: {
                switch store.settingsTab {
                case nil: return store.currentPath
                case .bibliography: return Self.bibliographyTag
                case .plugins: return Self.pluginsTag
                case .style: return Self.styleTag
                default: return Self.settingsTag
                }
            },
            set: { path in
                switch path {
                case Self.settingsTag?: store.showSettings(.project)
                case Self.bibliographyTag?: store.showSettings(.bibliography)
                case Self.pluginsTag?: store.showSettings(.plugins)
                case Self.styleTag?: store.showSettings(.style)
                case let path? where !path.isEmpty: store.openFile(path)
                default: break
                }
            }
        )
    }

    var body: some View {
        let loose = project.filesNotInTOC.filter { !store.ignoredFiles.contains($0) }
        List(selection: selection) {
            Section(project.hasExplicitTOC ? "Book" : "Book (order inferred)") {
                nodes(project.toc)
            }
            if !loose.isEmpty {
                Section("Not in table of contents") {
                    ForEach(loose, id: \.self) { path in
                        Label(path, systemImage: "doc")
                            .foregroundStyle(.secondary)
                            .tag(path)
                            .draggable(SidebarDrag.file(path))
                            .help("Drag into the book, or right-click to add it")
                            .contextMenu { looseFileMenu(path) }
                    }
                }
            }
            if !project.imageFiles.isEmpty {
                Section("Figures") {
                    ForEach(project.imageFiles, id: \.self) { path in
                        Label((path as NSString).lastPathComponent, systemImage: "photo")
                            .foregroundStyle(.secondary)
                            .help("\(path) — drag into a page to insert a figure (⇧ for just the image)")
                            .draggable(SidebarDrag.file(path))
                            .contextMenu {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url(for: path)]) }
                                if path.lowercased().hasSuffix(".pdf") {
                                    let svg = (path as NSString).deletingPathExtension + ".svg"
                                    Button("Make SVG for the Web") { store.makeSVG(for: path, undoManager: undoManager) }
                                        .disabled(project.imageFiles.contains(svg) || !store.canMakeSVG)
                                }
                            }
                    }
                }
            }
            Section("Project") {
                Label("Project Settings", systemImage: "gearshape").tag(Self.settingsTag)
                    .help("This book's settings, written to myst.yml (⌥⌘,). Settings for all books: ⌘,")
                // The tag goes last: on top of .badge, so the row can be selected.
                Label("Bibliography", systemImage: "books.vertical")
                    .badge(project.bibFiles.count)
                    .tag(Self.bibliographyTag)
                Label("Plugins", systemImage: "puzzlepiece.extension")
                    .badge(project.plugins.count)
                    .tag(Self.pluginsTag)
                Label("Style", systemImage: "paintbrush")
                    .tag(Self.styleTag)
                    .help("Fonts, sizes and colours of the website")
            }
        }
        .listStyle(.sidebar)
        // Files dropped on the list but not on a row go to the end of the book (pages) or into
        // images/ and the bibliography.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in handleDrop(providers, onto: nil) }
        // SwiftUI's sidebar list does not always redraw when a row moves between sections (a page
        // removed from the book stayed in it, and section headers vanished). A new identity for
        // every change of structure rebuilds it; which parts are open is kept in the store.
        .id(structureKey(loose: loose))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Menu {
                    Button("New Chapter…") { store.presentNewChapter(in: nil) }
                    Menu("New Chapter from Template") {
                        ForEach(TemplateLibrary.pageTemplates(projectRoot: nil)) { template in
                            Button(template.name) {
                                // The sheet opens with this template chosen.
                                UserDefaults.standard.set(template.id, forKey: "newPage.template")
                                store.presentNewChapter(in: nil)
                            }
                        }
                    }
                    Button("New Part…") { store.isShowingNewPart = true }
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New chapter or part")
                .accessibilityLabel("New chapter or part")
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .onDeleteCommand { store.removeSelectedFromBook(undoManager: undoManager) }
    }

    /// A drop on a row (or the list when `entry` is nil): files from Finder are copied into the
    /// book; sidebar items (TOC entries, loose files) are moved or added as before.
    private func handleDrop(_ providers: [NSItemProvider], onto entry: TOCEntry?) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if !fileProviders.isEmpty {
            Task { @MainActor in
                var urls: [URL] = []
                for provider in fileProviders {
                    if let url = await Self.loadFileURL(provider) { urls.append(url) }
                }
                store.importFiles(urls, onto: entry, undoManager: undoManager)
            }
            return true
        }
        guard let entry else { return false }
        Task { @MainActor in
            var items: [String] = []
            for provider in providers where provider.canLoadObject(ofClass: NSString.self) {
                if let text = await Self.loadString(provider) { items.append(text) }
            }
            store.drop(items, onto: entry, undoManager: undoManager)
        }
        return true
    }

    static func loadFileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    private static func loadString(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { text, _ in continuation.resume(returning: text as? String) }
        }
    }

    /// The table of contents as rows; parts open and close with the store's `expandedParts`.
    private func nodes(_ entries: [TOCEntry]) -> AnyView {
        AnyView(ForEach(entries) { entry in
            if entry.children.isEmpty {
                decorated(entry)
            } else {
                DisclosureGroup(isExpanded: Binding(
                    get: { store.expandedParts.contains(entry.id) },
                    set: { open in
                        if open { store.expandedParts.insert(entry.id) } else { store.expandedParts.remove(entry.id) }
                    }
                )) {
                    nodes(entry.children)
                } label: {
                    decorated(entry)
                }
            }
        })
    }

    private func decorated(_ entry: TOCEntry) -> some View {
        row(for: entry)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { dropHighlight(for: entry) }
            .draggable(SidebarDrag.entry(entry.id))
            .onDrop(of: [.fileURL, .plainText], isTargeted: Binding(
                get: { dropTarget == entry.id },
                set: { targeted in
                    if targeted {
                        dropTarget = entry.id
                    } else if dropTarget == entry.id {
                        dropTarget = nil
                    }
                }
            )) { providers in
                dropTarget = nil
                return handleDrop(providers, onto: entry)
            }
            .contextMenu { menu(for: entry) }
    }

    /// Changes whenever entries are added, removed or moved, or files leave or join the book.
    private func structureKey(loose: [String]) -> String {
        func walk(_ entries: [TOCEntry]) -> String {
            entries.map { $0.id.uuidString + "(" + walk($0.children) + ")" }.joined(separator: ",")
        }
        return walk(project.toc) + "|" + loose.joined(separator: ",")
    }

    @ViewBuilder
    private func row(for entry: TOCEntry) -> some View {
        let title = project.displayTitle(for: entry)
        switch entry.kind {
        case .file(let path):
            let exists = project.fileExists(path)
            Label {
                Text(title)
            } icon: {
                Image(systemName: exists ? "doc.text" : "exclamationmark.triangle")
                    .foregroundStyle(exists ? Color.secondary : Color.orange)
            }
            .help(exists ? path : "\(path) is listed in myst.yml but does not exist")
            .tag(exists ? path : "")
        case .group:
            // A part has no page to open; clicking its name opens or closes it.
            Label(title, systemImage: store.expandedParts.contains(entry.id) ? "book" : "book.closed")
                .fontWeight(.semibold)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if store.expandedParts.contains(entry.id) { store.expandedParts.remove(entry.id) } else { store.expandedParts.insert(entry.id) }
                    }
                }
        case .pattern(let pattern):
            Label(pattern, systemImage: "doc.on.doc")
                .foregroundStyle(.secondary)
                .help("All files matching \(pattern)")
        case .url(let url):
            Label(title, systemImage: "link")
                .help(url)
        }
    }

    /// Dropping on a part puts the item into it, so the part is highlighted. Dropping on a page
    /// puts the item before it, so a line marks the gap above the page.
    @ViewBuilder
    private func dropHighlight(for entry: TOCEntry) -> some View {
        if dropTarget == entry.id {
            if entry.isGroup {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor.opacity(0.22))
                    .padding(.horizontal, -6)
                    .padding(.vertical, -2)
            } else {
                VStack {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                        .offset(y: -3)
                    Spacer()
                }
            }
        }
    }

    // MARK: Context menus

    @ViewBuilder
    private func menu(for entry: TOCEntry) -> some View {
        let title = project.displayTitle(for: entry)
        if entry.isGroup {
            Button("New Chapter in “\(title)”…") { store.presentNewChapter(in: entry.id) }
            Button("Rename Part…") { store.renameRequest = .part(entry.id) }
        } else if let path = entry.file, project.fileExists(path) {
            Button("Rename…") { store.renameRequest = .page(path) }
        }
        Divider()
        moveItems(for: entry)
        Divider()
        Button(entry.isGroup ? "Remove Part (Keep Chapters)" : "Remove from Book") {
            store.removeFromBook(entry.id, undoManager: undoManager)
        }
        if let path = entry.file, project.fileExists(path) {
            Button("Move to Trash…", role: .destructive) { store.pendingTrash = path }
        }
    }

    @ViewBuilder
    private func moveItems(for entry: TOCEntry) -> some View {
        let location = project.toc.location(of: entry.id)
        let siblings = location.flatMap { project.toc.children(of: $0.parent) } ?? []
        Button("Move Up") { store.move(entry.id, by: -1, undoManager: undoManager) }
            .disabled(location.map { $0.index == 0 } ?? true)
        Button("Move Down") { store.move(entry.id, by: 1, undoManager: undoManager) }
            .disabled(location.map { $0.index == siblings.count - 1 } ?? true)
        Menu("Move To") {
            Button("End of Book") {
                store.move(entry.id, toParent: nil, at: project.toc.count, undoManager: undoManager)
            }
            .disabled(location?.parent == nil && location?.index == project.toc.count - 1)
            let targets = project.toc.allGroups.filter { !entry.contains($0.id) }
            if !targets.isEmpty { Divider() }
            ForEach(targets) { group in
                Button(project.displayTitle(for: group)) {
                    store.move(entry.id, toParent: group.id, at: group.children.count, undoManager: undoManager)
                }
            }
        }
    }

    @ViewBuilder
    private func looseFileMenu(_ path: String) -> some View {
        Button("Add to End of Book") { store.addToBook(path, in: nil, undoManager: undoManager) }
        let groups = project.toc.allGroups
        if !groups.isEmpty {
            Menu("Add to Part") {
                ForEach(groups) { group in
                    Button(project.displayTitle(for: group)) {
                        store.addToBook(path, in: group.id, undoManager: undoManager)
                    }
                }
            }
        }
        Divider()
        Button("Ignore") { store.ignore(path) }
        Button("Rename…") { store.renameRequest = .page(path) }
        Button("Move to Trash…", role: .destructive) { store.pendingTrash = path }
    }
}
