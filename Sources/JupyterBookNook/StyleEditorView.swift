import AppKit
import BookModel
import SwiftUI

/// The Style screen (sidebar › Project › Style): the parts of a page on the left, the settings of
/// the chosen one in the middle, and the preview or the book's CSS files on the right. Changes are
/// written to the book's stylesheet shortly after they are made, so the preview follows them.
struct StyleEditorView: View {
    @Environment(BookStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    let project: BookProject

    @State private var style = BookStyle()
    @State private var elementID: String?
    /// The CSS last written or read, to tell the editor's own changes from undo and edits elsewhere.
    @State private var lastCSS = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var isNamingStyle = false
    @State private var libraryRevision = 0
    @AppStorage("style.rightPane") private var rightPane = RightPane.preview

    enum RightPane: String { case preview, css }

    init(project: BookProject, element: String = StyleElement.all[0].id) {
        self.project = project
        _elementID = State(initialValue: element)
    }

    private var element: StyleElement? { elementID.flatMap(StyleElement.named) }

    var body: some View {
        HSplitView {
            elementList
                .frame(minWidth: 190, idealWidth: 210, maxWidth: 260)
            VStack(spacing: 0) {
                if let element {
                    StyleElementForm(element: element, style: $style)
                } else {
                    ContentUnavailableView("Choose a part of the page", systemImage: "paintbrush")
                }
            }
            .frame(minWidth: 340, idealWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 0) {
                HStack {
                    Picker("", selection: $rightPane) {
                        Text("Preview").tag(RightPane.preview)
                        Text("CSS Files").tag(RightPane.css)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    if store.build.isUpdatingPreviewStyle {
                        ProgressView().controlSize(.small)
                    }
                    Button("Update Preview", systemImage: "arrow.triangle.2.circlepath", action: updatePreview)
                        .disabled(store.build.previewURL == nil)
                        .help(store.build.previewURL == nil ? "The preview is not running" : "Saves the style now and shows it in the preview (⌘R)")
                        .keyboardShortcut("r", modifiers: .command)
                }
                .padding(8)
                Divider()
                switch rightPane {
                case .preview: PreviewPane()
                case .css: StyleCSSFiles(project: project, style: style)
                }
            }
            .frame(minWidth: 320, idealWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            readFromDisk()
            takeElementRequest()
        }
        .onChange(of: store.styleElementRequest) { takeElementRequest() }
        .onChange(of: store.fileRevision) {
            // Undo, or the file changed elsewhere: follow it unless a change of ours is pending.
            guard saveTask == nil else { return }
            let before = lastCSS
            readFromDisk()
            if lastCSS != before { store.build.updatePreviewStyle(expecting: lastCSS) }
        }
        .onChange(of: style) {
            guard style.css != lastCSS else { return }
            scheduleSave()
        }
        .sheet(isPresented: $isNamingStyle) {
            NameStyleSheet(initial: style.name) { name in
                store.saveStyleToLibrary(style, named: name)
                style.name = name
                libraryRevision += 1
            }
        }
    }

    /// Shows the part another screen asked for (e.g. tables, from the table assistant).
    private func takeElementRequest() {
        guard let requested = store.styleElementRequest else { return }
        elementID = requested
        store.styleElementRequest = nil
    }

    // MARK: Left column

    private var elementList: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Style").font(.system(size: 22, weight: .bold))
                Text(style.name.isEmpty ? (style.isEmpty ? "Theme default" : "Your own") : style.name)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                stylesMenu
                    .padding(.top, 4)
            }
            .padding(12)
            List(StyleElement.all, selection: $elementID) { element in
                HStack {
                    Label(element.name, systemImage: element.symbol)
                    Spacer()
                    if style.isSet(element) || element.controls.contains(where: { $0.kind.isConfig && project.configValue($0.configPath) != nil }) {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                            .help("Changed from the theme")
                    }
                }
                .tag(element.id)
            }
            .listStyle(.sidebar)
            Divider()
            Text("Saved to \(project.stylesheet ?? DarkFigures.defaultStylesheet) (site.options.style) as you go. ⌘Z undoes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
        }
    }

    private var stylesMenu: some View {
        let _ = libraryRevision
        let own = StyleLibrary.styles()
        return Menu("Styles") {
            Section("Built in") {
                ForEach(BookStyle.builtIn, id: \.name) { preset in
                    Button(preset.name) { load(preset) }
                }
            }
            Section("Your styles") {
                if own.isEmpty { Text("None saved yet") }
                ForEach(own, id: \.url) { item in
                    Button(item.name) {
                        do { load(try StyleLibrary.load(item.url)) } catch { store.errorMessage = error.localizedDescription }
                    }
                }
            }
            Divider()
            Button("Save to Your Styles…") { isNamingStyle = true }
            Button("Load from Another Book…") {
                if let other = store.chooseStyleFromAnotherBook() { load(other) }
            }
            if !own.isEmpty {
                Menu("Delete from Your Styles") {
                    ForEach(own, id: \.url) { item in
                        Button(item.name) {
                            try? StyleLibrary.delete(item.url)
                            libraryRevision += 1
                        }
                    }
                }
            }
            Button("Show Your Styles in Finder") {
                try? FileManager.default.createDirectory(at: StyleLibrary.folder, withIntermediateDirectories: true)
                NSWorkspace.shared.activateFileViewerSelecting([StyleLibrary.folder])
            }
            Divider()
            Button("Reset to Theme Default") { load(BookStyle.builtIn[0]) }
                .disabled(style.isEmpty)
        }
        .fixedSize()
    }

    // MARK: Reading and writing

    private func readFromDisk() {
        guard let current = store.project else { return }
        let disk = current.style
        lastCSS = disk.css
        if disk != style { style = disk }
    }

    /// Loading a style is saved at once, as its own undo step.
    private func load(_ other: BookStyle) {
        saveTask?.cancel()
        saveTask = nil
        style = other.loaded(into: style)
        lastCSS = style.css
        store.saveStyle(style, actionName: "Load Style “\(other.name)”", undoManager: undoManager)
        store.build.updatePreviewStyle(expecting: lastCSS)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            save()
            saveTask = nil
        }
    }

    /// Writes the style and has the preview pick it up when MyST has rebuilt it.
    private func save() {
        lastCSS = style.css
        store.saveStyle(style, undoManager: undoManager)
        store.build.updatePreviewStyle(expecting: lastCSS)
    }

    /// Saves a pending change at once, then updates the preview.
    private func updatePreview() {
        saveTask?.cancel()
        saveTask = nil
        save()
    }
}

/// The settings of one part of the page.
struct StyleElementForm: View {
    let element: StyleElement
    @Binding var style: BookStyle

    var body: some View {
        Form {
            Section {
                ForEach(element.controls) { control in
                    StyleControlRow(control: control, style: $style)
                }
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(element.name).font(.title2.bold()).foregroundStyle(.primary)
                    Text(element.summary).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 6)
                .textCase(nil)
            } footer: {
                HStack {
                    Text("Settings left at “Theme default” keep the look of MyST's theme.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset \(element.name)") { style.reset(element) }
                        .disabled(!style.isSet(element))
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// One setting: a font menu, a slider, colours for light and dark mode, or a menu of choices.
struct StyleControlRow: View {
    let control: StyleControl
    @Binding var style: BookStyle

    private func binding(dark: Bool = false) -> Binding<String?> {
        Binding(get: { style.value(control, dark: dark) }, set: { style.set(control, to: $0, dark: dark) })
    }

    var body: some View {
        Group {
            switch control.kind {
            case .font:
                FontControl(label: control.label, value: binding())
            case .number(let unit, let range, let step):
                NumberControl(label: control.label, value: binding(), unit: unit, range: range, step: step)
            case .color:
                LabeledContent(control.label) {
                    HStack(spacing: 14) {
                        ColorControl(label: "Light", value: binding())
                        ColorControl(label: "Dark", value: binding(dark: true))
                    }
                }
            case .choice(let choices):
                Picker(control.label, selection: binding()) {
                    Text("Theme default").tag(String?.none)
                    ForEach(choices, id: \.value) { choice in
                        Text(choice.label).tag(String?.some(choice.value))
                    }
                }
            case .configText(let placeholder, let multiline):
                ConfigTextControl(control: control, placeholder: placeholder, multiline: multiline)
            case .configFlag:
                ConfigFlagControl(control: control)
            }
        }
        .help(control.help ?? "")
    }
}

/// A text setting in myst.yml (the site name, a footer). Written when it is committed: Return,
/// leaving the field, or Apply for Markdown.
private struct ConfigTextControl: View {
    @Environment(BookStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    let control: StyleControl
    let placeholder: String
    let multiline: Bool
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var saved: String { store.project?.configValue(control.configPath) ?? "" }

    var body: some View {
        let _ = store.fileRevision
        VStack(alignment: .leading, spacing: 6) {
            if multiline {
                Text(control.label)
                TextEditor(text: $draft)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 70, maxHeight: 140)
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text(placeholder).foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
                HStack {
                    Text("Markdown, as in a page. Shown on every page of the site.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Apply") { commit() }
                        .disabled(draft == saved)
                }
            } else {
                TextField(control.label, text: $draft, prompt: Text(placeholder))
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { if !focused { commit() } }
            }
        }
        .onAppear { draft = saved }
        .onChange(of: saved) { draft = saved }
    }

    private func commit() {
        guard draft != saved else { return }
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        store.setConfigValue(control.configPath, to: value.isEmpty ? nil : .string(multiline ? draft : value),
                             summary: "\(control.label) changed", undoManager: undoManager)
    }
}

/// A true/false setting in myst.yml (hide search, hide the table of contents, …).
private struct ConfigFlagControl: View {
    @Environment(BookStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    let control: StyleControl

    var body: some View {
        let _ = store.fileRevision
        Toggle(control.label, isOn: Binding(
            get: { store.project?.configValue(control.configPath)?.lowercased() == "true" },
            set: { on in
                store.setConfigValue(control.configPath, to: on ? .plain("true") : nil,
                                     summary: "\(control.label) \(on ? "on" : "off")", undoManager: undoManager)
            }
        ))
    }
}

private struct FontControl: View {
    let label: String
    @Binding var value: String?

    private var isOther: Bool { value != nil && StyleFont.matching(value!) == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(label, selection: Binding<String>(
                get: { value.map { StyleFont.matching($0)?.name ?? "other" } ?? "" },
                set: { name in
                    if name.isEmpty { value = nil } else if name == "other" { value = value ?? "Georgia, serif" } else { value = StyleFont.all.first { $0.name == name }?.stack }
                }
            )) {
                Text("Theme default").tag("")
                Section("On every computer") {
                    ForEach(StyleFont.local) { font in
                        Text(font.name).tag(font.name)
                    }
                }
                Section("Web fonts (from Google Fonts)") {
                    ForEach(StyleFont.web) { font in
                        Text(font.name).tag(font.name)
                    }
                }
                Divider()
                Text("Other…").tag("other")
            }
            if isOther {
                TextField("CSS font-family", text: Binding(get: { value ?? "" }, set: { value = $0 }))
                    .font(.system(.body, design: .monospaced))
            }
            if let font = value.flatMap(StyleFont.matching), font.googleFamily != nil {
                Text("Readers' browsers load \(font.name) from Google Fonts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct NumberControl: View {
    let label: String
    @Binding var value: String?
    let unit: String
    let range: ClosedRange<Double>
    let step: Double

    private var number: Double? {
        guard let value else { return nil }
        return Double(value.trimmingCharacters(in: .letters.union(.whitespaces)).replacingOccurrences(of: "%", with: ""))
    }

    private func format(_ n: Double) -> String {
        let text = n == n.rounded() ? String(Int(n)) : String(format: step < 0.1 ? "%.2f" : "%.1f", n)
        return text + unit
    }

    var body: some View {
        LabeledContent(label) {
            HStack {
                Slider(value: Binding(
                    get: { number ?? (range.lowerBound + range.upperBound) / 2 },
                    set: { value = format(($0 / step).rounded() * step) }
                ), in: range)
                .opacity(number == nil ? 0.45 : 1)
                Text(value ?? "default")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(value == nil ? .secondary : .primary)
                    .frame(width: 62, alignment: .trailing)
                ResetButton(isShown: value != nil) { value = nil }
            }
        }
    }
}

private struct ColorControl: View {
    let label: String
    @Binding var value: String?

    var body: some View {
        HStack(spacing: 4) {
            ColorPicker(label, selection: Binding(
                get: { value.flatMap(Color.init(css:)) ?? Color.gray.opacity(0.25) },
                set: { value = $0.cssHex }
            ), supportsOpacity: false)
            .labelsHidden()
            .help(value ?? "Theme default")
            Text(label).fixedSize()
            if value == nil {
                Text("default").font(.caption).foregroundStyle(.secondary)
            }
            ResetButton(isShown: value != nil) { value = nil }
        }
    }
}

private struct ResetButton: View {
    let isShown: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Back to the theme default")
        .opacity(isShown ? 1 : 0)
        .disabled(!isShown)
    }
}

/// The book's CSS files, next to the editor: the site's stylesheet as the editor writes it, and
/// the others as they are on disk.
struct StyleCSSFiles: View {
    @Environment(BookStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    let project: BookProject
    let style: BookStyle
    @State private var chosen: String?

    private var siteFile: String { project.stylesheet ?? DarkFigures.defaultStylesheet }

    var body: some View {
        let _ = store.fileRevision
        let files = Array(Set(project.cssFiles + [siteFile])).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let shown = chosen.flatMap { files.contains($0) ? $0 : nil } ?? siteFile
        let isSite = shown == siteFile
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("File", selection: Binding(get: { shown }, set: { chosen = $0 })) {
                    ForEach(files, id: \.self) { file in
                        Text(file == siteFile ? "\(file) — the site's stylesheet" : file).tag(file)
                    }
                }
                .fixedSize()
                Spacer()
                if !isSite, project.fileExists(atPath: shown) {
                    Button("Use for the Site") { store.useStylesheet(shown, undoManager: undoManager) }
                        .help("Lists this file under site.options.style in myst.yml instead of \(siteFile)")
                }
                Button("Open in Editor") { store.openFile(shown) }
                    .disabled(!project.fileExists(atPath: shown))
                    .help("Edit the file as text. CSS of your own goes below “nook-style end”.")
            }
            ScrollView {
                Text(isSite ? style.css : ((try? String(contentsOf: project.url(for: shown), encoding: .utf8)) ?? ""))
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            if isSite, !project.fileExists(atPath: siteFile) {
                Text("\(siteFile) does not exist yet. The first change creates it and lists it in myst.yml.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }
}

private extension BookProject {
    func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: path).path)
    }
}

/// Names a style before it is saved to the library.
struct NameStyleSheet: View {
    @Environment(\.dismiss) private var dismiss
    let initial: String
    let save: (String) -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save to Your Styles").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(commit)
            Text("Your styles can be loaded into any book (Styles menu). A style of the same name is replaced.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 320, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .onAppear { name = initial }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        save(trimmed)
        dismiss()
    }
}

extension Color {
    /// `#rgb` and `#rrggbb`; other CSS colours are not shown (the picker starts grey).
    init?(css: String) {
        var hex = css.trimmingCharacters(in: .whitespaces)
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let n = UInt32(hex, radix: 16) else { return nil }
        self.init(.sRGB, red: Double((n >> 16) & 0xFF) / 255, green: Double((n >> 8) & 0xFF) / 255, blue: Double(n & 0xFF) / 255)
    }

    var cssHex: String? {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        func byte(_ v: CGFloat) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(color.redComponent), byte(color.greenComponent), byte(color.blueComponent))
    }
}
