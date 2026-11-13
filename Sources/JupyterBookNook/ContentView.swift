import BookModel
import SwiftUI

struct ContentView: View {
    @Environment(BookStore.self) private var store
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if let project = store.project {
                BookWindow(project: project)
            } else {
                WelcomeView()
            }
        }
        // Only views can open the Settings window; the store keeps the action for menus and the palette.
        .onAppear { store.openSettingsWindow = { openSettings() } }
        .sheet(isPresented: Binding(get: { store.isShowingNewProject }, set: { store.isShowingNewProject = $0 })) {
            NewProjectSheet()
        }
        .sheet(isPresented: Binding(get: { store.isShowingTour }, set: { store.isShowingTour = $0 })) {
            WelcomeTour()
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}

struct WelcomeView: View {
    @Environment(BookStore.self) private var store

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "books.vertical")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)
            Text("JupyterBookNook")
                .font(.largeTitle.weight(.semibold))
            Text("Open a Jupyter Book 2 project — a folder that contains myst.yml.")
                .foregroundStyle(.secondary)
            HStack {
                Button("New Project…") { store.isShowingNewProject = true }
                Button("Open Project…") { store.showOpenPanel() }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .padding(.top, 6)
            Button {
                store.openDocumentation()
            } label: {
                Label("Open the JupyterBookNook Documentation", systemImage: "book.pages")
            }
            .buttonStyle(.link)
            .help("A project that explains MyST syntax and this app; it is created the first time")
            if !store.recentBooks.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("RECENT")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 2)
                    ForEach(store.recentBooks) { book in
                        RecentBookRow(book: book) { store.open(URL(fileURLWithPath: book.path)) }
                    }
                }
                .frame(width: 380)
                .padding(.top, 18)
            }
            if store.build.toolchain(for: nil) == nil, !store.build.isDetecting {
                Button("MyST is not set up yet — set it up for building and previewing…") { store.build.isShowingSetup = true }
                    .buttonStyle(.link)
                    .font(.callout)
                    .padding(.top, 10)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: Binding(get: { store.build.isShowingSetup }, set: { store.build.isShowingSetup = $0 })) {
            ToolchainSetupSheet()
        }
    }
}

private struct RecentBookRow: View {
    let book: BookStore.RecentBook
    let open: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "book.closed").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(book.title).lineLimit(1)
                Text((book.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isHovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: open)
        .help(book.path)
    }
}

struct BookWindow: View {
    @Environment(BookStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    let project: BookProject

    var body: some View {
        @Bindable var store = store
        NavigationSplitView(columnVisibility: $store.sidebarVisibility) {
            SidebarView(project: project)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 380)
        } detail: {
            VStack(spacing: 0) {
                if let problem = project.configProblem {
                    ConfigProblemBar(problem: problem)
                    Divider()
                }
                VSplitView {
                    Group {
                        if store.settingsTab == .bibliography {
                            BibliographyView(project: project)
                        } else if store.settingsTab == .plugins {
                            PluginsView(project: project)
                        } else if store.settingsTab == .style {
                            StyleEditorView(project: project)
                        } else if store.settingsTab != nil {
                            ProjectSettingsView(project: project)
                        } else if store.documents.isEmpty {
                            // No tabs open: an empty area until a page is chosen in the sidebar.
                            Color(nsColor: .underPageBackgroundColor)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            HSplitView {
                                if store.viewMode.showsEditor {
                                    EditorArea()
                                        .frame(minWidth: 320)
                                }
                                if store.viewMode.showsPreview {
                                    PreviewPane()
                                        .frame(minWidth: 320)
                                }
                            }
                        }
                    }
                    .frame(minHeight: 240)
                    if store.build.isShowingPanel {
                        BuildPanel()
                            .frame(minHeight: 110, idealHeight: 180)
                    }
                }
                if !store.isFocusMode {
                    Divider()
                    StatusBar()
                }
            }
            .overlay(alignment: .topTrailing) {
                if store.isFocusMode {
                    FocusModeExitButton()
                }
            }
            .overlay(alignment: .top) {
                if store.isShowingSnippets {
                    ZStack(alignment: .top) {
                        Color.black.opacity(0.08)
                            .contentShape(Rectangle())
                            .onTapGesture { store.isShowingSnippets = false }
                        SnippetPicker()
                            .padding(.top, 60)
                    }
                } else if let mode = store.palette {
                    ZStack(alignment: .top) {
                        Color.black.opacity(0.08)
                            .contentShape(Rectangle())
                            .onTapGesture { store.palette = nil }
                        PaletteView(initialMode: mode)
                            .padding(.top, 60)
                    }
                }
            }
            // Without an open tab there is no outline: the column is hidden (not switched off).
            .inspector(isPresented: Binding(
                get: { store.isShowingOutline && !(store.documents.isEmpty && store.settingsTab == nil) },
                set: { if !(store.documents.isEmpty && store.settingsTab == nil) { store.isShowingOutline = $0 } }
            )) {
                OutlineInspector()
                    .inspectorColumnWidth(min: 180, ideal: 230, max: 360)
            }
        }
        .toolbar(store.isFocusMode ? .hidden : .automatic, for: .windowToolbar)
        .navigationTitle(project.title)
        .navigationSubtitle(store.settingsTab == .bibliography ? "Bibliography" : store.settingsTab == .plugins ? "Plugins · myst.yml"
            : store.settingsTab == .style ? "Style · \(project.stylesheet ?? DarkFigures.defaultStylesheet)"
            : store.settingsTab != nil ? "Project settings · myst.yml" : store.currentPath ?? "")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.presentNewChapter(in: nil)
                } label: {
                    Label("New Chapter", systemImage: "doc.badge.plus")
                }
                .help("New chapter (⇧⌘N)")
            }
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $store.viewMode) {
                    ForEach(ViewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Editor (⌘1), Split (⌘2) or Preview (⌘3)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if let tab = store.settingsTab, tab != .bibliography {
                    Button("Open myst.yml as text") { store.openConfigAsText() }
                        .help("Edit everything the forms do not cover")
                }
                Button {
                    store.buildBook()
                } label: {
                    if store.build.isBuilding {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Build", systemImage: "hammer")
                    }
                }
                .help("Build the book as HTML (⌘B)")
                .disabled(store.build.isBuilding)
                Menu {
                    Button("Export HTML Site…") { store.isShowingExport = true }
                    Button("Reveal HTML in Finder") { store.revealBuild() }
                    Button("Export as Zip…") { store.exportZip() }
                    Divider()
                    Button("Open Preview in Browser") {
                        if let url = store.build.previewURL { NSWorkspace.shared.open(url) } else { store.viewMode = .split }
                    }
                    Divider()
                    Button("Export Settings…") { store.showSettings(.exports) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export the built HTML")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.isShowingOutline.toggle()
                } label: {
                    Label("Outline", systemImage: "sidebar.right")
                }
                .help("Show or hide the outline (⌥⌘0)")
            }
        }
        .sheet(isPresented: $store.isShowingNewChapter) {
            NewPageSheet(kind: .chapter, project: project, initialPart: store.newChapterPart) { title, part, template in
                store.addChapter(title: title, in: part, template: template, undoManager: undoManager)
            }
        }
        .sheet(isPresented: $store.isShowingNewPart) {
            NewPageSheet(kind: .part, project: project, initialPart: nil) { title, _, _ in
                store.addPart(title: title, undoManager: undoManager)
            }
        }
        .sheet(isPresented: $store.isShowingExport) {
            ExportSheet(project: project)
        }
        .sheet(isPresented: Binding(get: { store.build.isShowingSetup }, set: { store.build.isShowingSetup = $0 })) {
            ToolchainSetupSheet()
        }
        .sheet(item: $store.tableAssistant) { request in
            TableAssistantView(request: request, apply: { store.applyTable($0, for: request) }, showTableStyle: { store.showTableStyle() })
        }
        .sheet(item: $store.renameRequest) { request in
            RenameSheet(
                request: request,
                project: project,
                renamePage: { path, title, newPath in
                    store.renamePage(path, title: title, newPath: newPath, undoManager: undoManager)
                },
                renamePart: { id, title in store.renamePart(id, to: title, undoManager: undoManager) }
            )
        }
        .confirmationDialog(
            "Move “\(store.pendingTrash.map { project.pageTitles[$0] ?? $0 } ?? "")” to the Trash?",
            isPresented: Binding(get: { store.pendingTrash != nil }, set: { if !$0 { store.pendingTrash = nil } }),
            presenting: store.pendingTrash
        ) { path in
            Button("Move to Trash", role: .destructive) {
                store.moveToTrash(path, undoManager: undoManager)
            }
            Button("Cancel", role: .cancel) {}
        } message: { path in
            Text("\(path) is removed from the table of contents and moved to the Trash. You can undo this with ⌘Z.")
        }
        .overlay(alignment: .bottom) {
            if let notice = store.notice {
                NoticeBanner(notice: notice)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: store.notice?.id)
    }
}

/// Shown while myst.yml cannot be read: the book keeps its last table of contents, and changes to
/// it wait until the file is fixed.
struct ConfigProblemBar: View {
    @Environment(BookStore.self) private var store
    let problem: ConfigProblem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 1) {
                Text("myst.yml cannot be read").fontWeight(.semibold)
                Text(problem.description).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Show in myst.yml") { store.showConfigProblem() }
                .buttonStyle(.borderedProminent)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.red.opacity(0.10))
    }
}

/// The only control in focus mode: faint until the pointer comes near.
struct FocusModeExitButton: View {
    @Environment(BookStore.self) private var store
    @State private var isHovering = false

    var body: some View {
        Button {
            store.toggleFocusMode()
        } label: {
            Label("Exit Focus Mode", systemImage: "arrow.down.right.and.arrow.up.left")
                .labelStyle(.iconOnly)
                .padding(8)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(isHovering ? 1 : 0.25)
        .onHover { isHovering = $0 }
        .help("Exit focus mode (⇧⌘↩)")
        .padding(10)
    }
}

/// "myst.yml updated — Undo": shown after every structural change.
struct NoticeBanner: View {
    @Environment(BookStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    let notice: BookStore.Notice
    @State private var isShowingChange = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(notice.message)
            if let change = notice.change, change.changesConfig {
                Button("Show Change") { isShowingChange.toggle() }
                    .popover(isPresented: $isShowingChange, arrowEdge: .top) {
                        ConfigDiffView(change: change)
                    }
            }
            if let change = notice.change {
                Button("Undo") {
                    // Drop the matching ⌘Z entry so it cannot be undone twice.
                    undoManager?.removeAllActions(withTarget: store)
                    store.revert(change)
                }
            }
            Button {
                store.notice = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.bottom, 18)
        .task(id: notice.id) {
            try? await Task.sleep(for: .seconds(6))
            // Stay while the diff is open.
            while isShowingChange { try? await Task.sleep(for: .seconds(1)) }
            if store.notice?.id == notice.id { store.notice = nil }
        }
    }
}

/// The lines of myst.yml a structural change touched, with a little context.
struct ConfigDiffView: View {
    let change: StructuralChange

    var body: some View {
        let hunks = LineDiff.hunks(LineDiff.diff(change.configBefore, change.configAfter))
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                Text("myst.yml")
                    .font(.headline)
                    .padding(.bottom, 6)
                ForEach(Array(hunks.enumerated()), id: \.offset) { _, line in
                    row(line)
                }
            }
            .padding(14)
        }
        .frame(minWidth: 380, maxWidth: 560, maxHeight: 420)
    }

    @ViewBuilder
    private func row(_ line: LineDiff.Line?) -> some View {
        switch line {
        case nil:
            Text("⋯").foregroundStyle(.tertiary)
        case .same(let text):
            code("  " + text).foregroundStyle(.secondary)
        case .removed(let text):
            code("− " + text).background(Color.red.opacity(0.15))
        case .added(let text):
            code("+ " + text).background(Color.green.opacity(0.15))
        }
    }

    private func code(_ text: String) -> some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}

/// The bar at the bottom of the window: MyST version and problems on the left,
/// the state of the live preview on the right.
struct StatusBar: View {
    @Environment(BookStore.self) private var store

    var body: some View {
        let build = store.build
        let toolchain = build.toolchain(for: store.project?.root)
        let problems = build.buildMessages.isEmpty ? build.previewMessages : build.buildMessages
        HStack(spacing: 14) {
            if let toolchain {
                Text("\(toolchain.tool.rawValue) \(build.versions[toolchain] ?? "")")
                    .help(toolchain.displayName)
            } else {
                Button("MyST not set up") { build.isShowingSetup = true }
                    .buttonStyle(.link)
            }
            if let page = store.currentDocument?.diagnostics, !page.isEmpty {
                Button("\(page.count) problem\(page.count == 1 ? "" : "s") on this page") {
                    store.isShowingOutline = true
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .help("Found while editing; listed in the inspector (⌥⌘0)")
            }
            Button(problems.isEmpty ? "Build: no problems" : "Build: \(problems.count) problem\(problems.count == 1 ? "" : "s")") {
                build.isShowingPanel.toggle()
            }
            .buttonStyle(.plain)
            .help("Problems MyST reported; show or hide the build panel (⇧⌘Y)")
            Spacer()
            previewStatus
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }

    @ViewBuilder
    private var previewStatus: some View {
        switch store.build.previewState {
        case .running:
            Label("Preview live", systemImage: "circle.fill").labelStyle(LiveLabelStyle())
        case .starting:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Starting preview…")
            }
        case .failed:
            Button("Preview stopped — Restart") { store.build.restartPreview() }
                .buttonStyle(.link)
        case .stopped:
            Text("Preview off")
        }
    }
}
