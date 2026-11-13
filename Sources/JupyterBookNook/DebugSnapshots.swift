#if DEBUG
import AppKit
import BookModel
import BuildService
import MystSyntax
import SwiftUI

/// Renders the app's screens to PNG files and quits, for checking layouts without clicking
/// through the app: `NOOK_SNAPSHOT=/some/folder swift run JupyterBookNook path/to/book`.
/// Debug builds only.
@MainActor
enum DebugSnapshots {
    static func runIfRequested(store: BookStore) {
        guard let folder = ProcessInfo.processInfo.environment["NOOK_SNAPSHOT"], let project = store.project else { return }
        let output = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let dark = ProcessInfo.processInfo.environment["NOOK_SNAPSHOT_DARK"] != nil
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if ProcessInfo.processInfo.environment["NOOK_SNAPSHOT_SCENARIO"] == "menus" {
            // The menu bar once SwiftUI has built it (the File menu is renamed Project).
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                for item in NSApp.mainMenu?.items ?? [] {
                    print("[menus] \(item.title): \((item.submenu?.items ?? []).filter { !$0.isHidden }.map(\.title).filter { !$0.isEmpty }.joined(separator: " | "))")
                }
                // Settings file: written and read back (not applied, so the app's settings stay).
                let settings = EditorSettings.shared
                var custom = settings.snapshot
                custom.customColors = .from(.ocean)
                custom.theme = "custom"
                custom.defaultAuthor = "Test Author"
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                let data = try? encoder.encode(custom)
                let back = data.flatMap { try? JSONDecoder().decode(EditorSettings.Snapshot.self, from: $0) }
                print("[settings] round trip: \(back.flatMap { try? encoder.encode($0) } == data), colours: \(back?.customColors.pairs.count ?? 0)")
                let empty = try? JSONDecoder().decode(EditorSettings.Snapshot.self, from: Data("{}".utf8))
                print("[settings] empty file gives defaults: \(empty?.theme == "calm" && empty?.fontSize == 13 && empty?.defaultAuthor == "")")
                exit(0)
            }
            return
        }
        if ProcessInfo.processInfo.environment["NOOK_SNAPSHOT_SCENARIO"] == "apply-exports" {
            // The per-page grid before and after Apply to All Pages, in one hosting view.
            store.pageExportsEnabled = true
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
            let host = NSHostingView(rootView: PageExportsSettings(project: project).environment(store).padding().frame(width: 760, height: 360))
            window.contentView = host
            func shot(_ name: String) {
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name))
            }
            shot("grid-before.png")
            store.setFormat("md", onAllPages: true, undoManager: nil)
            shot("grid-md.png")
            store.setFormat("md", onAllPages: false, undoManager: nil)
            shot("grid-after.png")
            exit(0)
        }
        if ProcessInfo.processInfo.environment["NOOK_SNAPSHOT_SCENARIO"] == "sync-lines",
           let page = ProcessInfo.processInfo.environment["NOOK_SNAPSHOT_BOOK_PAGE"],
           let text = try? String(contentsOf: project.url(for: page), encoding: .utf8) {
            // The editor's side of the line sync: scroll to a source line, read the top line back.
            let scrollView = MystTextEditor.makeTextKit1ScrollView()
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = scrollView
            let textView = scrollView.documentView as! MystTextView
            textView.textContainerInset = NSSize(width: 18, height: 14)
            textView.string = text
            if let storage = textView.textStorage { MystHighlighter.highlight(storage) }
            scrollView.layoutSubtreeIfNeeded()
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            let starts = NSTextView.lineStarts(of: text)
            for hidden in [false, true] {
                textView.applyYAMLFolds(frontMatter: hidden, options: hidden)
                textView.layoutManager?.ensureLayout(for: textView.textContainer!)
                var report: [String] = []
                for line in [1.0, 12.0, 46.0, 124.5, 200.25, 333.5, 480.0] {
                    textView.scrollToSourceLine(line, offset: 4, lineStarts: starts)
                    let back = textView.sourceLine(atTopOffset: 4, lineStarts: starts)
                    report.append(String(format: "%.2f→%.2f", line, back))
                }
                print("[sync-lines] \(hidden ? "front matter and options hidden" : "plain"): " + report.joined(separator: "  "))
            }
            // The last screenful: the target moves towards the end with the other side's share.
            let clip = scrollView.contentView
            let maxY = textView.frame.height - clip.bounds.height
            var ends: [String] = []
            for share in [0.0, 0.25, 0.5, 1.0] {
                textView.scrollToSourceLine(Double(starts.count) - 30, offset: 4, lineStarts: starts, end: share)
                ends.append(String(format: "end %.2f: y %.0f of %.0f (weight back %.2f)", share, clip.bounds.origin.y, maxY, textView.endWeight))
            }
            textView.scrollToSourceLine(1, offset: 4, lineStarts: starts)
            ends.append(String(format: "top: weight %.2f", textView.endWeight))
            print("[sync-lines] " + ends.joined(separator: "  |  "))
            exit(0)
        }
        if ProcessInfo.processInfo.environment["NOOK_SNAPSHOT_SCENARIO"] == "plugins" {
            // Reads the plugins in the background (with Node when found), then switches one off and
            // on and creates a new one. Prints what the store and the index know at each step.
            Task { @MainActor in
                @MainActor func settle() async {
                    for _ in 0..<100 where store.pluginStatus.values.contains(.reading) {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
                @MainActor func report(_ step: String) {
                    print("[plugins] \(step)")
                    for (entry, enabled) in store.allPlugins {
                        let status: String
                        switch store.pluginStatus[entry.source] {
                        case .read(let spec)?: status = "read \(spec.name ?? "-"): directives \(spec.directives.map(\.name)) roles \(spec.roles.map(\.name))"
                        case .failed(let message)?: status = "failed: \(message)"
                        case .executable?: status = "executable"
                        case .reading?: status = "reading"
                        case nil: status = "none"
                        }
                        print("[plugins]   \(enabled ? "on " : "off") \(entry.source): \(status)")
                    }
                    print("[plugins]   index directives \(store.index.pluginDirectives.map(\.name)) unread \(store.index.hasUnreadPlugins)")
                    let page = ProcessInfo.processInfo.environment["NOOK_SNAPSHOT_BOOK_PAGE"] ?? store.project?.toc.allFiles.first ?? ""
                    print("[plugins]   problems in \(page): \(store.index.diagnostics(for: page).map(\.message))")
                }
                store.inspectPlugins()
                await settle()
                report("opened")
                if ProcessInfo.processInfo.environment["NOOK_SNAPSHOT_REPORT_ONLY"] != nil { exit(0) }
                let broken = store.allPlugins.first { $0.entry.source.contains("broken") }?.entry
                let executable = store.allPlugins.first { $0.entry.isExecutable }?.entry
                for entry in [broken, executable].compactMap({ $0 }) { store.setPlugin(entry, enabled: false, undoManager: nil) }
                await settle()
                report("broken and executable switched off")
                if let broken { store.setPlugin(broken, enabled: true, undoManager: nil) }
                await settle()
                report("broken switched on")
                store.createPlugin(named: "Side Notes", undoManager: nil)
                await settle()
                report("created Side Notes; open tab: \(store.currentPath ?? "-")")
                print("[plugins] myst.yml:\n" + (store.project?.configText ?? ""))
                exit(0)
            }
            return
        }
        if ProcessInfo.processInfo.environment["NOOK_SNAPSHOT_SCENARIO"] == "drops",
           let outside = ProcessInfo.processInfo.environment["NOOK_SNAPSHOT_OUTSIDE"] {
            // Files from Finder dropped on a sidebar row, then an image, an image with Shift and a
            // page dropped on the editor. Prints the results; drag sessions themselves are not run.
            let folder = URL(fileURLWithPath: outside)
            Task { @MainActor in
                var urls: [URL] = []
                for name in ["dropped-notes.md", "plot.png", "sidebar.pdf", "sidebar.zip"]
                    where FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
                    if let provider = NSItemProvider(contentsOf: folder.appendingPathComponent(name)),
                       let url = await SidebarView.loadFileURL(provider) { urls.append(url) }
                }
                let target = store.project?.toc.first { $0.file == "gradient-descent.md" }
                store.importFiles(urls, onto: target, undoManager: nil)
                print("[drops] toc:", store.project?.toc.allFiles ?? [])
                print("[drops] images:", store.project?.imageFiles ?? [])
                print("[drops] download folder:", (try? FileManager.default.contentsOfDirectory(atPath: project.root.appendingPathComponent("download").path)) ?? [])

                let textView = (MystTextEditor.makeTextKit1ScrollView().documentView as? MystTextView)!
                textView.string = "Line one.\n\nSome text here.\n"
                let page = "part/page.md"
                textView.dropProvider = { items, plain in store.editorDrop(items, plain: plain, page: page, undoManager: nil) }
                @MainActor func drop(_ write: (NSPasteboard) -> Void, at index: Int, plain: Bool) {
                    let pasteboard = NSPasteboard(name: NSPasteboard.Name("nook-test-\(UUID().uuidString)"))
                    pasteboard.clearContents()
                    write(pasteboard)
                    let handled = textView.handleDrop(pasteboard, at: index, plain: plain)
                    print("[drops] handled=\(handled) selection=\((textView.string as NSString).substring(with: textView.selectedRange()))")
                }
                let image = project.root.appendingPathComponent("images/plot.png")
                drop({ $0.writeObjects([image as NSURL]) }, at: 11, plain: false)
                drop({ $0.writeObjects([image as NSURL]) }, at: 4, plain: true)
                if let entry = store.project?.toc.first(where: { $0.file == "calculus.md" }) {
                    drop({ $0.setString(SidebarDrag.entry(entry.id), forType: .string) }, at: (textView.string as NSString).length, plain: false)
                }
                let outsideImage = folder.appendingPathComponent("plot.png")
                drop({ $0.writeObjects([outsideImage as NSURL]) }, at: 0, plain: true)
                let pdf = folder.appendingPathComponent("diagram.pdf")
                if FileManager.default.fileExists(atPath: pdf.path) {
                    drop({ $0.writeObjects([pdf as NSURL]) }, at: (textView.string as NSString).length, plain: false)
                    // The SVG is made in the background.
                    try? await Task.sleep(for: .seconds(3))
                }
                let zip = folder.appendingPathComponent("handout.zip")
                if FileManager.default.fileExists(atPath: zip.path) {
                    drop({ $0.writeObjects([zip as NSURL]) }, at: (textView.string as NSString).length, plain: false)
                }
                // A screenshot on the clipboard (TIFF only), pasted as a figure.
                if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                   let tiff = rep.tiffRepresentation {
                    let pasteboard = NSPasteboard(name: NSPasteboard.Name("nook-test-\(UUID().uuidString)"))
                    pasteboard.clearContents()
                    pasteboard.setData(tiff, forType: .tiff)
                    textView.setSelectedRange(NSRange(location: 0, length: 0))
                    let handled = textView.handleDrop(pasteboard, replacing: textView.selectedRange(), plain: false, allowsImageData: true)
                    print("[drops] pasted image handled=\(handled)")
                }
                print("[drops] text:\n" + textView.string)
                print("[drops] images after outside drop:", store.project?.imageFiles ?? [])
                exit(0)
            }
            return
        }
        if ProcessInfo.processInfo.environment["NOOK_SNAPSHOT_SCENARIO"] == "tables" {
            // The editor with its "TA" badges, then the assistant for a pipe and a list table.
            let text = """
            # Results

            The runs, as a pipe table:

            | Method | Steps | Loss |
            |:-------|------:|:----:|
            | SGD    | 1000  | 0.31 |
            | Adam   | 400   | 0.12 |

            :::{list-table} Notation used in this chapter
            :header-rows: 1
            :label: tbl-notation

            * - Symbol
              - Meaning
            * - $\\eta$
              - The learning rate,
                a small number
            * - $L$
              - The loss
            :::

            After the tables.
            """
            let scrollView = MystTextEditor.makeTextKit1ScrollView()
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 460), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = scrollView
            let textView = scrollView.documentView as! MystTextView
            textView.textContainerInset = NSSize(width: 18, height: 14)
            textView.frame = CGRect(origin: .zero, size: scrollView.contentSize)
            textView.string = text
            if let storage = textView.textStorage { MystHighlighter.highlight(storage) }
            let tables = MystTables.all(in: text)
            textView.tableStarts = tables.map(\.range.location)
            scrollView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            if let rep = scrollView.bitmapImageRepForCachingDisplay(in: scrollView.bounds) {
                scrollView.cacheDisplay(in: scrollView.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("tables-editor.png"))
            }
            let badge = textView.tableBadgeRect(for: tables[0].range.location)!
            print("[tables] badge hit: \(textView.tableBadge(at: NSPoint(x: badge.midX, y: badge.midY)) == tables[0].range.location)")
            for (index, block) in tables.enumerated() {
                let request = TableAssistantRequest(path: "results.md", range: block.range, original: "", table: block.table, isNew: false, line: 5)
                render(TableAssistantView(request: request, apply: { _ in }, showTableStyle: {}), size: CGSize(width: 980, height: 620), store: store,
                       to: output.appendingPathComponent("tables-assistant-\(index).png"))
            }
            let new = TableAssistantRequest(path: "results.md", range: NSRange(location: 0, length: 0), original: "", table: .empty(), isNew: true, line: 1)
            UserDefaults.standard.set(true, forKey: "tableAssistant.showsMarkdown")
            render(TableAssistantView(request: new, apply: { _ in }, showTableStyle: {}), size: CGSize(width: 980, height: 620), store: store,
                   to: output.appendingPathComponent("tables-assistant-new.png"))
            UserDefaults.standard.removeObject(forKey: "tableAssistant.showsMarkdown")
            exit(0)
        }
        if ProcessInfo.processInfo.environment["NOOK_SNAPSHOT_SCENARIO"] == "tab-stops" {
            // Insert the Figure snippet into an indented line, type into the stops, ⇥ between them.
            let textView = (MystTextEditor.makeTextKit1ScrollView().documentView as? MystTextView)!
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = textView.enclosingScrollView
            textView.string = "- item\n  \nafter\n"
            if let figure = TemplateLibrary.builtInSnippets.first(where: { $0.name == "Figure" }) {
                let insertion = figure.snippetInsertion(selection: "", values: TemplateValues(title: ""))
                textView.insert(insertion.text, stops: insertion.stops, replacing: NSRange(location: 9, length: 0), actionName: "Insert Figure")
            }
            func show(_ step: String) {
                let selected = (textView.string as NSString).substring(with: textView.selectedRange())
                print("[stops] \(step): selected=“\(selected)” stops=\(textView.tabStops.count)")
            }
            show("inserted")
            textView.insertText("plots/loss.svg", replacementRange: textView.selectedRange())
            textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
            show("tab 1")
            textView.insertText("loss", replacementRange: textView.selectedRange())
            textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
            show("tab 2")
            textView.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
            show("backtab")
            textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
            textView.insertText("The loss falls.", replacementRange: textView.selectedRange())
            textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
            show("past last")
            print("[stops] text:\n" + textView.string)
            exit(0)
        }
        if ProcessInfo.processInfo.environment["NOOK_SNAPSHOT_SCENARIO"] == "remove-chapter" {
            // Add a chapter at the end, render the sidebar, remove it from the book, render again.
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            let host = NSHostingView(rootView: SidebarHost().environment(store).frame(width: 300, height: 700))
            window.contentView = host
            func shot(_ name: String) {
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name))
            }
            shot("sidebar-0.png")
            store.addChapter(title: "Extra", in: nil, undoManager: nil)
            shot("sidebar-1-added.png")
            if let path = store.currentPath, let entry = store.project?.entries(forFile: path).first {
                store.removeFromBook(entry.id, undoManager: nil)
            }
            shot("sidebar-2-removed.png")
            exit(0)
        }
        store.pageExportsEnabled = true
        if let document = store.currentDocument {
            let defaults = UserDefaults.standard
            let saved = defaults.object(forKey: "inspector.pageInfo")
            defaults.set(true, forKey: "inspector.pageInfo")
            if let note = (document.text as NSString).range(of: "{note}").location as Int?, note != NSNotFound {
                document.selection = NSRange(location: note + 10, length: 0)
            }
            render(OutlineInspector(), size: CGSize(width: 280, height: 1500), store: store, to: output.appendingPathComponent("inspector.png"))
            defaults.set(saved, forKey: "inspector.pageInfo")
        }
        for tab in SettingsTab.formTabs {
            store.settingsTab = tab
            render(ProjectSettingsView(project: project), size: CGSize(width: 1180, height: 1500), store: store,
                   to: output.appendingPathComponent("settings-\(tab).png"))
        }
        // All tabs closed: an empty area next to the sidebar.
        if ProcessInfo.processInfo.environment["NOOK_SNAPSHOT_ONLY"] == "no-tabs" {
            let open = store.documents.map(\.path)
            let mode = store.viewMode
            store.viewMode = .split
            for path in open { store.close(path) }
            render(ContentView(), size: CGSize(width: 1300, height: 700), store: store, to: output.appendingPathComponent("no-tabs.png"))
            store.viewMode = mode
            exit(0)
        }
        // A PDF tab: not for editing, shown in the preview.
        if let pdf = project.imageFiles.first(where: { $0.hasSuffix(".pdf") }),
           ProcessInfo.processInfo.environment["NOOK_SNAPSHOT_ONLY"].map({ "viewonly".contains($0) }) ?? true {
            let shown = store.currentPath
            store.openFile(pdf)
            print("[viewonly] \(pdf): open \(store.currentDocument?.isViewOnly == true), error \(store.errorMessage ?? "none")")
            render(HStack(spacing: 0) { EditorArea(); Divider(); PreviewPane() }, size: CGSize(width: 1300, height: 640), store: store,
                   to: output.appendingPathComponent("viewonly-pdf.png"))
            // A text file without a preview, and an SVG shown as a drawing.
            for other in ["myst.yml", project.imageFiles.first(where: { $0.hasSuffix(".svg") })].compactMap({ $0 }) {
                store.openFile(other)
                render(HStack(spacing: 0) { EditorArea(); Divider(); PreviewPane() }, size: CGSize(width: 1300, height: 640), store: store,
                       to: output.appendingPathComponent("viewonly-\((other as NSString).pathExtension).png"))
            }
            if let shown { store.openFile(shown) }
        }
        // The style editor with a built-in style, showing the CSS next to it.
        if ProcessInfo.processInfo.environment["NOOK_SNAPSHOT_ONLY"].map({ "style".contains($0) || $0.contains("style") }) ?? true {
            let defaults = UserDefaults.standard
            let pane = defaults.string(forKey: "style.rightPane")
            defaults.set("css", forKey: "style.rightPane")
            store.saveStyle(BookStyle.builtIn[1], undoManager: nil)
            if let project = store.project {
                for element in ["text", "h2", "links", "admonitions"] {
                    render(StyleEditorView(project: project, element: element), size: CGSize(width: 1280, height: 820), store: store,
                           to: output.appendingPathComponent("style-\(element).png"))
                }
            }
            if let pane { defaults.set(pane, forKey: "style.rightPane") } else { defaults.removeObject(forKey: "style.rightPane") }
        }
        // Plugins, read without Node (the background reading cannot finish inside this block).
        for entry in store.allPlugins.map(\.entry) where !entry.isExecutable && !entry.isURL {
            if let text = try? String(contentsOf: project.url(for: BookProject.normalized(entry.source)), encoding: .utf8) {
                store.pluginStatus[entry.source] = PluginInspector.scan(text).map { .read($0) } ?? .failed(PluginInspectorError.notAPlugin.localizedDescription)
            }
        }
        render(PluginsView(project: project), size: CGSize(width: 900, height: 640), store: store, to: output.appendingPathComponent("plugins.png"))
        store.isShowingNewPlugin = false
        render(NewPluginSheet(), size: CGSize(width: 440, height: 200), store: store, to: output.appendingPathComponent("plugins-new.png"))
        render(AddPluginURLSheet { _ in }, size: CGSize(width: 480, height: 280), store: store, to: output.appendingPathComponent("plugins-url.png"))
        let shownTab = store.appSettingsTab
        store.reloadPluginLibrary()
        store.libraryTask?.cancel()
        for plugin in store.pluginLibrary {
            if case .file(let url) = plugin.source, let text = try? String(contentsOf: url, encoding: .utf8) {
                store.libraryStatus[plugin.id] = PluginInspector.scan(text).map { .read($0) } ?? .failed(PluginInspectorError.notAPlugin.localizedDescription)
            } else {
                store.libraryStatus[plugin.id] = .failed("The server answered 404.")
            }
        }
        store.appSettingsTab = .plugins
        render(AppSettingsView(), size: CGSize(width: 680, height: 600), store: store, to: output.appendingPathComponent("app-settings-plugins.png"))
        store.appSettingsTab = .templates
        render(AppSettingsView(), size: CGSize(width: 900, height: 680), store: store, to: output.appendingPathComponent("app-settings-templates.png"))
        store.appSettingsTab = shownTab
        store.settingsTab = nil
        render(SnippetPicker(), size: CGSize(width: 680, height: 460), store: store, to: output.appendingPathComponent("snippets.png"))
        render(EditorSettingsView(), size: CGSize(width: 980, height: 720), store: store, to: output.appendingPathComponent("settings-editor.png"))
        render(SyntaxColorsSheet(), size: CGSize(width: 860, height: 560), store: store, to: output.appendingPathComponent("syntax-colours.png"))
        if let document = store.currentDocument {
            let settings = EditorSettings.shared
            let saved = (settings.showsLineNumbers, settings.limitsLineWidth)
            settings.showsLineNumbers = true
            render(MystTextEditor(document: document, scrollSync: store.scrollSync, onCreate: { _ in }) { _, _ in [] },
                   size: CGSize(width: 900, height: 600), store: store, to: output.appendingPathComponent("editor-lines.png"))
            // The book view: everything styled, then with the cursor in a paragraph with markup.
            let page = ProcessInfo.processInfo.environment["NOOK_SNAPSHOT_BOOK_PAGE"]
            let bookDocument = page.flatMap { path in try? OpenDocument(path: path, root: project.root) } ?? document
            bookDocument.selection = NSRange(location: 0, length: 0)
            store.buildIndexNow()
            render(MystTextEditor(document: bookDocument, scrollSync: store.scrollSync, bookView: true,
                                  resolveReference: { store.referenceText(role: $0, target: $1, page: bookDocument.path) }, onCreate: { _ in }) { _, _ in [] },
                   size: CGSize(width: 900, height: 1400), store: store, to: output.appendingPathComponent("editor-book.png"))
            if let marker = ProcessInfo.processInfo.environment["NOOK_SNAPSHOT_BOOK_CURSOR"] {
                let location = (bookDocument.text as NSString).range(of: marker).location
                if location != NSNotFound { bookDocument.selection = NSRange(location: location, length: 0) }
            }
            render(MystTextEditor(document: bookDocument, scrollSync: store.scrollSync, bookView: true,
                                  resolveReference: { store.referenceText(role: $0, target: $1, page: bookDocument.path) }, onCreate: { _ in }) { _, _ in [] },
                   size: CGSize(width: 900, height: 1400), store: store, to: output.appendingPathComponent("editor-book-cursor.png"))
            document.selection = NSRange(location: max(0, (document.text as NSString).range(of: "The gradient").location), length: 0)
            render(MystTextEditor(document: document, scrollSync: store.scrollSync, focusMode: true, onCreate: { _ in }) { _, _ in [] },
                   size: CGSize(width: 1200, height: 700), store: store, to: output.appendingPathComponent("editor-focus.png"))
            // Folding: all directives folded, then the first one opened again.
            if ProcessInfo.processInfo.environment["NOOK_SNAPSHOT_ONLY"].map({ "editor-folded".contains($0) }) ?? true {
                let scrollView = MystTextEditor.makeTextKit1ScrollView()
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = scrollView
                let textView = scrollView.documentView as! MystTextView
                textView.textContainerInset = NSSize(width: 18, height: 14)
                textView.string = document.text
                if let storage = textView.textStorage { MystHighlighter.highlight(storage) }
                let ruler = LineNumberRuler(textView: textView, scrollView: scrollView)
                scrollView.verticalRulerView = ruler
                scrollView.hasVerticalRuler = true
                scrollView.rulersVisible = true
                textView.foldAll()
                ruler.textChanged()
                func shot(_ name: String) {
                    scrollView.layoutSubtreeIfNeeded()
                    textView.layoutManager?.ensureLayout(for: textView.textContainer!)
                    scrollView.display()
                    guard let rep = scrollView.bitmapImageRepForCachingDisplay(in: scrollView.bounds) else { return }
                    scrollView.cacheDisplay(in: scrollView.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name))
                }
                shot("editor-folded.png")
                print("[fold] folds:", textView.foldingLayoutManager?.folds ?? [])
                if let first = textView.foldingLayoutManager?.folds.first { textView.foldingLayoutManager?.unfold(first) }
                // Typing before a fold moves it; typing inside the opened block keeps the others.
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                textView.insertText("New first line.\n", replacementRange: NSRange(location: 0, length: 0))
                print("[fold] after typing:", textView.foldingLayoutManager?.folds ?? [])
                // As the editor does after each change.
                if let storage = textView.textStorage { MystHighlighter.highlight(storage) }
                ruler.textChanged()
                shot("editor-folded-2.png")
            }
            // Front matter and directive options hidden (Settings › Editor).
            if ProcessInfo.processInfo.environment["NOOK_SNAPSHOT_ONLY"].map({ "editor-yaml".contains($0) }) ?? true {
                let scrollView = MystTextEditor.makeTextKit1ScrollView()
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = scrollView
                let textView = scrollView.documentView as! MystTextView
                textView.textContainerInset = NSSize(width: 18, height: 14)
                textView.string = """
                ---
                title: Gradient descent
                authors:
                  - Ada Lovelace
                keywords: [optimisation, gradients]
                ---

                # Gradient descent

                :::{figure} images/grid.svg
                :label: fig-grid
                :width: 60%
                The grid.
                :::

                Some text after the figure.

                """
                if let storage = textView.textStorage { MystHighlighter.highlight(storage) }
                let ruler = LineNumberRuler(textView: textView, scrollView: scrollView)
                scrollView.verticalRulerView = ruler
                scrollView.hasVerticalRuler = true
                scrollView.rulersVisible = true
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
                textView.applyYAMLFolds(frontMatter: true, options: true)
                ruler.textChanged()
                print("[yaml] folds:", textView.foldingLayoutManager?.folds ?? [])
                scrollView.layoutSubtreeIfNeeded()
                textView.layoutManager?.ensureLayout(for: textView.textContainer!)
                scrollView.display()
                if let rep = scrollView.bitmapImageRepForCachingDisplay(in: scrollView.bounds) {
                    scrollView.cacheDisplay(in: scrollView.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("editor-yaml.png"))
                }
            }
            (settings.showsLineNumbers, settings.limitsLineWidth) = saved
        }
        store.buildIndexNow()
        render(PaletteView(initialMode: .open), size: CGSize(width: 640, height: 480), store: store, to: output.appendingPathComponent("palette-open.png"))
        render(PaletteView(initialMode: .open, initialQuery: "gd"), size: CGSize(width: 640, height: 480), store: store, to: output.appendingPathComponent("palette-query.png"))
        render(PaletteView(initialMode: .open, initialQuery: "sec"), size: CGSize(width: 640, height: 480), store: store, to: output.appendingPathComponent("palette-labels.png"))
        render(PaletteView(initialMode: .commands), size: CGSize(width: 640, height: 480), store: store, to: output.appendingPathComponent("palette-commands.png"))
        render(WelcomeView(), size: CGSize(width: 900, height: 640), store: store, to: output.appendingPathComponent("welcome.png"))
        render(WelcomeTour(), size: CGSize(width: 520, height: 470), store: store, to: output.appendingPathComponent("welcome-tour.png"))
        render(NewProjectSheet(), size: CGSize(width: 620, height: 720), store: store, to: output.appendingPathComponent("new-project.png"))
        render(NewProjectSheet(folder: project.root), size: CGSize(width: 620, height: 720), store: store, to: output.appendingPathComponent("new-project-existing.png"))
        render(NewProjectSheet(folder: output.appendingPathComponent("empty-folder")), size: CGSize(width: 620, height: 720), store: store, to: output.appendingPathComponent("new-project-folder.png"))
        render(ExportSheet(project: project), size: CGSize(width: 620, height: 640), store: store, to: output.appendingPathComponent("export.png"))
        render(NewPageSheet(kind: .chapter, project: project, initialPart: nil) { _, _, _ in }, size: CGSize(width: 440, height: 300), store: store,
               to: output.appendingPathComponent("new-chapter.png"))
        exit(0)
    }

    private static func render(_ view: some View, size: CGSize, store: BookStore, to url: URL) {
        // NOOK_SNAPSHOT_ONLY=settings-templates renders only the files whose names contain it.
        if let only = ProcessInfo.processInfo.environment["NOOK_SNAPSHOT_ONLY"], !url.lastPathComponent.contains(only) { return }
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view.environment(store).frame(width: size.width, height: size.height))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Let onAppear and the first layout pass run.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
/// The sidebar as the window shows it, following the store's project.
private struct SidebarHost: View {
    @Environment(BookStore.self) private var store

    var body: some View {
        if let project = store.project { SidebarView(project: project) }
    }
}
#endif
