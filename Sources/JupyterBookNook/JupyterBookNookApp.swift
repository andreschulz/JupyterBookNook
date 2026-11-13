import AppKit
import SwiftUI

@main
struct JupyterBookNookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = BookStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            BookCommands(store: store)
        }

        Settings {
            AppSettingsView()
                .environment(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationSignals: [DispatchSourceSignal] = []
    private var menuObservers: [NSObjectProtocol] = []

    static let projectMenuTitle = "Project"

    /// SwiftUI cannot rename the File menu, so it is renamed in the menu bar: the menu with
    /// "Open Project…" is called Project. SwiftUI rebuilds the menu bar now and then; the
    /// observers rename it again.
    private static func renameFileMenu() {
        guard let item = NSApp.mainMenu?.items.first(where: { $0.submenu?.items.contains { $0.title == "Open Project…" } == true }),
              item.title != projectMenuTitle else { return }
        item.title = projectMenuTitle
        item.submenu?.title = projectMenuTitle
    }

    /// AppIcon.png from the target's resource bundle, looked up without `Bundle.module`, which
    /// stops the app when the bundle is missing (e.g. a binary copied on its own).
    static var appIcon: NSImage? {
        let name = "JupyterBookNook_JupyterBookNook.bundle"
        let places = [Bundle.main.resourceURL, Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
        for place in places {
            let url = place.appendingPathComponent(name).appendingPathComponent("AppIcon.png")
            if let image = NSImage(contentsOf: url) { return image }
        }
        return nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched with `swift run` there is no app bundle; this gives the
        // process a Dock icon, a menu bar and keyboard focus.
        NSApp.setActivationPolicy(.regular)
        // Without a bundle there is no icon file either; the app's resources have one.
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") == nil, let icon = Self.appIcon {
            NSApp.applicationIconImage = icon
        }
        MainActor.assumeIsolated { EditorSettings.shared.applyAppearance() }
        Self.renameFileMenu()
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification] {
            menuObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                // After SwiftUI has finished changing the menu.
                DispatchQueue.main.async { Self.renameFileMenu() }
            })
        }
        NSApp.activate(ignoringOtherApps: true)
        // Ctrl-C in the terminal or `kill` quits like ⌘Q: pages are saved and the preview
        // server is stopped, instead of being left running.
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            terminationSignals.append(source)
        }
    }
}

struct BookCommands: Commands {
    let store: BookStore

    private func findButton(_ title: String, _ action: NSTextFinder.Action, key: Character, modifiers: EventModifiers = .command) -> some View {
        Button(title) { store.performFind(action) }
        .keyboardShortcut(KeyEquivalent(key), modifiers: modifiers)
        .disabled(store.currentDocument == nil)
    }

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Templates…") { store.showAppSettings(.templates) }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Project…") { store.isShowingNewProject = true }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("Open Project…") { store.showOpenPanel() }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(store.recentBooks) { book in
                    Button(book.title) { store.open(URL(fileURLWithPath: book.path)) }
                }
                if !store.recentBooks.isEmpty { Divider() }
                Button("Clear Menu") { store.clearRecentBooks() }
                    .disabled(store.recentBooks.isEmpty)
            }
            Divider()
            Button("New Chapter…") { store.presentNewChapter(in: nil) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(store.project == nil)
            Button("New Part…") { store.isShowingNewPart = true }
                .disabled(store.project == nil)
            Divider()
            Button("Project Settings…") { store.showSettings() }
                .keyboardShortcut(",", modifiers: [.command, .option])
                .disabled(store.project == nil)
            Button("Open myst.yml as Text") { store.openConfigAsText() }
                .disabled(store.project == nil)
            Button("Plugins") { store.showSettings(.plugins) }
                .disabled(store.project == nil)
            Button("Style") { store.showSettings(.style) }
                .disabled(store.project == nil)
        }
        // SwiftUI apps get no Find menu; these send the standard find-bar actions to the editor.
        CommandGroup(after: .textEditing) {
            Button("Paste Image Only") {
                if let textView = store.editorTextView as? MystTextView, !textView.pasteImage(plain: true) { NSSound.beep() }
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .disabled(store.currentDocument == nil || store.settingsTab != nil)
            Button("Insert Snippet…") { store.showSnippets() }
                .keyboardShortcut("t")
                .disabled(store.currentDocument == nil || store.settingsTab != nil)
            Button("Table Assistant…") { store.showTableAssistant() }
                .keyboardShortcut("t", modifiers: [.command, .control])
                .disabled(store.currentDocument?.isPage != true || store.settingsTab != nil)
            Menu("Find") {
                findButton("Find…", .showFindInterface, key: "f")
                findButton("Find and Replace…", .showReplaceInterface, key: "f", modifiers: [.command, .option])
                findButton("Find Next", .nextMatch, key: "g")
                findButton("Find Previous", .previousMatch, key: "g", modifiers: [.command, .shift])
                findButton("Use Selection for Find", .setSearchString, key: "e")
            }
        }
        CommandMenu("Book") {
            Button("Build") { store.buildBook() }
                .keyboardShortcut("b")
                .disabled(store.project == nil || store.build.isBuilding)
            Button("Restart Preview") { store.build.restartPreview() }
                .disabled(store.project == nil)
            Button(store.build.isShowingPanel ? "Hide Build Panel" : "Show Build Panel") { store.build.isShowingPanel.toggle() }
                .keyboardShortcut("y", modifiers: [.command, .shift])
                .disabled(store.project == nil)
            Divider()
            Button("Export HTML Site…") { store.isShowingExport = true }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(store.project == nil)
            Button("Build Documents (PDF, Word…)") { store.buildDocuments() }
                .disabled(store.project == nil || store.build.isBuilding)
            Button("Export Settings…") { store.showSettings(.exports) }
                .disabled(store.project == nil)
            Button("Reveal HTML in Finder") { store.revealBuild() }
                .disabled(store.project == nil)
            Button("Export as Zip…") { store.exportZip() }
                .disabled(store.project == nil)
            Divider()
            Button("MyST Installation…") { store.build.isShowingSetup = true }
        }
        // No printing; ⌘P is Quick Open, as in code editors.
        CommandGroup(replacing: .printItem) {
            Button("Quick Open…") { store.palette = .open }
                .keyboardShortcut("p")
                .disabled(store.project == nil)
            Button("Command Palette…") { store.palette = .commands }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(store.project == nil)
        }
        CommandGroup(before: .windowList) {
            Button("Show Previous Tab") { store.selectTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(store.documents.count < 2)
            Button("Show Next Tab") { store.selectTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(store.documents.count < 2)
            Divider()
        }
        CommandGroup(before: .sidebar) {
            ForEach(Array(ViewMode.allCases.enumerated()), id: \.element) { index, mode in
                Button(mode.title) { store.viewMode = mode }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .disabled(store.project == nil)
            }
            Toggle("Sync Editor and Preview", isOn: Binding(get: { store.scrollSync.isEnabled }, set: { store.scrollSync.isEnabled = $0 }))
            Divider()
        }
        CommandGroup(after: .sidebar) {
            Menu("Folding") {
                Button("Fold") { (store.editorTextView as? MystTextView)?.foldAtCursor() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("Unfold") { (store.editorTextView as? MystTextView)?.unfoldAtCursor() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Divider()
                Button("Fold All Directives") { (store.editorTextView as? MystTextView)?.foldAll() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option, .shift])
                Button("Unfold All") { (store.editorTextView as? MystTextView)?.unfoldAll() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option, .shift])
                Divider()
                // Settings › Editor, for every page.
                Toggle("Hide Front Matter", isOn: Binding(get: { EditorSettings.shared.hidesFrontMatter }, set: { EditorSettings.shared.hidesFrontMatter = $0 }))
                Toggle("Hide Directive Options", isOn: Binding(get: { EditorSettings.shared.hidesDirectiveOptions }, set: { EditorSettings.shared.hidesDirectiveOptions = $0 }))
            }
            .disabled(store.currentDocument == nil || store.settingsTab != nil)
            Button(store.currentDocument?.isBookView == true ? "Source View" : "Book View") { store.currentDocument?.isBookView.toggle() }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(store.currentDocument?.isPage != true || store.settingsTab != nil)
            Button(store.isFocusMode ? "Exit Focus Mode" : "Focus Mode") { store.toggleFocusMode() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(store.currentDocument == nil && !store.isFocusMode)
            Button(store.isShowingOutline ? "Hide Outline" : "Show Outline") { store.isShowingOutline.toggle() }
                .keyboardShortcut("0", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .help) {
            Button("JupyterBookNook Documentation") { store.openDocumentation() }
            Button("Welcome Tour") { store.isShowingTour = true }
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { store.saveCurrent() }
                .keyboardShortcut("s")
                .disabled(store.currentDocument == nil)
            Button("Close Tab") {
                if let path = store.currentPath { store.close(path) }
            }
            .keyboardShortcut("w")
            .disabled(store.currentDocument == nil)
        }
    }
}
