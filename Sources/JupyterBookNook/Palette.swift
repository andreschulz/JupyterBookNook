import AppKit
import BookModel
import ProjectIndex
import SwiftUI

/// Quick Open (⌘P) finds pages, labels and files; the command palette (⇧⌘P) runs menu commands.
/// Typing ">" in Quick Open switches to commands, deleting it switches back.
enum PaletteMode {
    case open, commands
}

struct PaletteItem: Identifiable {
    enum Group: String, CaseIterable {
        case pages = "Pages"
        case labels = "Labels"
        case files = "Files"
        case commands = "Commands"
    }

    let id: String
    let group: Group
    let title: String
    var subtitle = ""
    var icon: String
    var shortcut = ""
    /// Extra text the filter searches (a page's path, a command's other names).
    var keywords: [String] = []
    var isEnabled = true
    let action: @MainActor () -> Void
}

struct PaletteView: View {
    @Environment(BookStore.self) private var store
    let initialMode: PaletteMode
    var initialQuery = ""
    @State private var query = ""
    @State private var selectedID: PaletteItem.ID?
    @State private var items: [PaletteItem] = []
    @FocusState private var searchFocused: Bool

    private var mode: PaletteMode { query.hasPrefix(">") ? .commands : .open }
    private var searchText: String { mode == .commands ? String(query.dropFirst()) : query }

    /// Items that match, best first; without a query, in their natural order (book order, menus).
    private var filtered: [PaletteItem] {
        let pool = items.filter { mode == .commands ? $0.group == .commands : $0.group != .commands }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            // Labels only appear once something is typed; there are too many to list.
            return pool.filter { $0.group != .labels }
        }
        let scored = pool.compactMap { item in FuzzyMatch.score(q, in: [item.title] + item.keywords).map { (item, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(60)
        // Kept together by kind, the kind with the best match first.
        var groups: [PaletteItem.Group] = []
        for (item, _) in scored where !groups.contains(item.group) { groups.append(item.group) }
        return groups.flatMap { group in scored.filter { $0.0.group == group }.map(\.0) }
    }

    private var selected: PaletteItem? {
        filtered.first { $0.id == selectedID } ?? filtered.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: mode == .commands ? "command" : "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                TextField(mode == .commands ? "Run a command…" : "Open a page, label or file…  (> for commands)", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($searchFocused)
                    .onSubmit(run)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let shown = filtered
                        ForEach(Array(shown.enumerated()), id: \.element.id) { offset, item in
                            if mode == .open, offset == 0 || shown[offset - 1].group != item.group {
                                Text(item.group.rawValue.uppercased())
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 14)
                                    .padding(.top, 8)
                                    .padding(.bottom, 3)
                            }
                            row(item).id(item.id)
                        }
                        if shown.isEmpty {
                            Text(mode == .commands ? "No command matches" : "Nothing matches “\(query)”")
                                .foregroundStyle(.secondary)
                                .padding(16)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onChange(of: selectedID) { if let selectedID { proxy.scrollTo(selectedID) } }
            }
            .frame(height: 360)
            Divider()
            Text(mode == .commands ? "↵ run · ↑↓ choose · esc close" : "↵ open · ↑↓ choose · > commands · esc close")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
        }
        .frame(width: 600)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .onAppear {
            items = PaletteItems.openItems(store) + PaletteItems.commands(store)
            query = (initialMode == .commands ? ">" : "") + initialQuery
            searchFocused = true
        }
        .onChange(of: query) { selectedID = filtered.first?.id }
    }

    private func row(_ item: PaletteItem) -> some View {
        let isSelected = item.id == selected?.id
        return HStack(spacing: 10) {
            Image(systemName: item.icon)
                .frame(width: 18)
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.white : item.isEnabled ? Color.primary : Color.secondary)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                }
            }
            Spacer()
            if !item.shortcut.isEmpty {
                Text(item.shortcut)
                    .font(.callout)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            selectedID = item.id
            run()
        }
        .onTapGesture { selectedID = item.id }
    }

    private func move(_ offset: Int) {
        let shown = filtered
        guard !shown.isEmpty else { return }
        let index = shown.firstIndex { $0.id == selected?.id } ?? 0
        selectedID = shown[(index + offset + shown.count) % shown.count].id
    }

    private func run() {
        guard let item = selected, item.isEnabled else { return }
        store.palette = nil
        // After the overlay is gone, so sheets and focus changes work.
        DispatchQueue.main.async { item.action() }
    }

    private func close() {
        store.palette = nil
        if let textView = store.editorTextView { textView.window?.makeFirstResponder(textView) }
    }
}

/// What the palette lists.
@MainActor
enum PaletteItems {
    static func openItems(_ store: BookStore) -> [PaletteItem] {
        guard let project = store.project else { return [] }
        var items: [PaletteItem] = []
        var seen = Set<String>()
        for page in store.bookPages where seen.insert(page).inserted {
            items.append(PaletteItem(id: "page:" + page, group: .pages, title: project.pageTitles[page] ?? page,
                                     subtitle: page, icon: "doc.text", keywords: [page]) { store.openFile(page) })
        }
        for page in project.markdownFiles where seen.insert(page).inserted {
            items.append(PaletteItem(id: "page:" + page, group: .pages, title: project.pageTitles[page] ?? page,
                                     subtitle: page + " · not in the table of contents", icon: "doc", keywords: [page]) { store.openFile(page) })
        }
        for entry in store.index.labels {
            let label = entry.label
            let title = label.title.map { "\(label.name) — \($0)" } ?? label.name
            items.append(PaletteItem(id: "label:\(entry.page):\(label.name):\(label.line)", group: .labels, title: title,
                                     subtitle: "\(label.kind.rawValue) · \(project.pageTitles[entry.page] ?? entry.page)",
                                     icon: "number", keywords: [label.name]) {
                store.openFile(entry.page)
                store.currentDocument?.reveal(label.range)
            })
        }
        items.append(PaletteItem(id: "file:myst.yml", group: .files, title: BookProject.configFileName,
                                 subtitle: "Project configuration as text", icon: "gearshape", keywords: ["config", "yaml"]) {
            store.openConfigAsText()
        })
        for file in project.bibFiles {
            items.append(PaletteItem(id: "file:" + file, group: .files, title: file, subtitle: "Bibliography",
                                     icon: "books.vertical", keywords: ["bibtex", "references"]) { store.showSettings(.bibliography) })
        }
        for image in project.imageFiles {
            items.append(PaletteItem(id: "file:" + image, group: .files, title: (image as NSString).lastPathComponent,
                                     subtitle: image + " · show in Finder", icon: "photo", keywords: [image]) {
                NSWorkspace.shared.activateFileViewerSelecting([project.url(for: image)])
            })
        }
        return items
    }

    static func commands(_ store: BookStore) -> [PaletteItem] {
        let hasBook = store.project != nil
        let hasPage = store.currentDocument != nil
        func command(_ title: String, _ icon: String, _ shortcut: String = "", keywords: [String] = [],
                     enabled: Bool = true, _ action: @escaping @MainActor () -> Void) -> PaletteItem {
            PaletteItem(id: "command:" + title, group: .commands, title: title, icon: icon, shortcut: shortcut,
                        keywords: keywords, isEnabled: enabled, action: action)
        }
        var items = [
            command("New Chapter…", "doc.badge.plus", "⇧⌘N", keywords: ["page", "add"], enabled: hasBook) { store.presentNewChapter(in: nil) },
            command("New Part…", "folder.badge.plus", keywords: ["section", "add"], enabled: hasBook) { store.isShowingNewPart = true },
            command("Insert Snippet…", "text.badge.plus", "⌘T", keywords: ["template"], enabled: hasPage) { store.showSnippets() },
            command("Table Assistant…", "tablecells", "⌃⌘T", keywords: ["table", "rows", "columns"], enabled: store.currentDocument?.isPage == true) {
                store.showTableAssistant()
            },
            command("Find…", "magnifyingglass", "⌘F", enabled: hasPage) { store.performFind(.showFindInterface) },
            command("Find and Replace…", "magnifyingglass", "⌥⌘F", enabled: hasPage) { store.performFind(.showReplaceInterface) },
            command("Save", "square.and.arrow.down", "⌘S", enabled: hasPage) { store.saveCurrent() },
            command("Close Tab", "xmark", "⌘W", enabled: hasPage) { if let path = store.currentPath { store.close(path) } },
            command("Build", "hammer", "⌘B", keywords: ["html"], enabled: hasBook && !store.build.isBuilding) { store.buildBook() },
            command("Restart Preview", "arrow.clockwise", keywords: ["server"], enabled: hasBook) { store.build.restartPreview() },
            command(store.build.isShowingPanel ? "Hide Build Panel" : "Show Build Panel", "rectangle.bottomthird.inset.filled", "⇧⌘Y",
                    keywords: ["log", "problems"], enabled: hasBook) { store.build.isShowingPanel.toggle() },
            command("Export HTML Site…", "square.and.arrow.up", "⇧⌘E", enabled: hasBook) { store.isShowingExport = true },
            command("Build Documents (PDF, Word…)", "doc.richtext", keywords: ["export", "pdf", "docx", "latex"],
                    enabled: hasBook && !store.build.isBuilding) { store.buildDocuments() },
            command("Export as Zip…", "doc.zipper", enabled: hasBook) { store.exportZip() },
            command("Reveal HTML in Finder", "folder", enabled: hasBook) { store.revealBuild() },
            command("Open myst.yml as Text", "gearshape", keywords: ["config", "yaml"], enabled: hasBook) { store.openConfigAsText() },
            command("Bibliography", "books.vertical", keywords: ["bibtex", "references", "citations"], enabled: hasBook) { store.showSettings(.bibliography) },
            command("Plugins", "puzzlepiece.extension", keywords: ["directives", "roles", "extensions"], enabled: hasBook) { store.showSettings(.plugins) },
            command("Style", "paintbrush", keywords: ["css", "fonts", "colours", "colors", "theme", "look"], enabled: hasBook) { store.showSettings(.style) },
            command("New Plugin…", "puzzlepiece.extension", keywords: ["directive", "role", "javascript"], enabled: hasBook) {
                store.showSettings(.plugins)
                store.isShowingNewPlugin = true
            },
        ]
        for tab in SettingsTab.formTabs {
            items.append(command("Project Settings: \(tab.rawValue)", "gearshape.2", tab == .project ? "⌥⌘," : "",
                                 keywords: ["book", "myst.yml"], enabled: hasBook) { store.showSettings(tab) })
        }
        for tab in AppSettingsTab.allCases {
            items.append(command("Settings: \(tab.rawValue)", "gearshape", tab == .editor ? "⌘," : "",
                                 keywords: tab == .templates ? ["snippets", "preferences", "all books"] : ["preferences", "app", "all books"]) {
                store.showAppSettings(tab)
            })
        }
        for (index, mode) in ViewMode.allCases.enumerated() {
            items.append(command("View: \(mode.title)", "rectangle.split.2x1", "⌘\(index + 1)", enabled: hasBook) { store.viewMode = mode })
        }
        items += [
            command(store.isShowingOutline ? "Hide Outline" : "Show Outline", "sidebar.right", "⌥⌘0", keywords: ["inspector"]) { store.isShowingOutline.toggle() },
            command(store.scrollSync.isEnabled ? "Stop Syncing Editor and Preview" : "Sync Editor and Preview", "arrow.up.arrow.down",
                    keywords: ["scroll"]) { store.scrollSync.isEnabled.toggle() },
            command("Show Next Tab", "arrow.right.square", "⇧⌘]", enabled: store.documents.count > 1) { store.selectTab(offset: 1) },
            command("Show Previous Tab", "arrow.left.square", "⇧⌘[", enabled: store.documents.count > 1) { store.selectTab(offset: -1) },
            command("New Project…", "book.closed", "⌥⌘N") { store.isShowingNewProject = true },
            command("Open Project…", "folder", "⌘O") { store.showOpenPanel() },
            command("JupyterBookNook Documentation", "book.pages", keywords: ["help", "manual", "syntax"]) { store.openDocumentation() },
            command("MyST Installation…", "shippingbox", keywords: ["toolchain", "node", "jupyter-book"]) { store.build.isShowingSetup = true },
        ]
        return items
    }
}
