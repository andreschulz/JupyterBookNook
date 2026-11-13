import AppKit
import BookModel
import BuildService
import SwiftUI

/// Project Settings (mockup 04): forms for `myst.yml`, the table of contents and the live file.
/// Every change is written to `myst.yml` shortly after typing stops, as a minimal text edit.
struct ProjectSettingsView: View {
    @Environment(BookStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    let project: BookProject

    /// What the forms show and edit.
    @State private var draft = ProjectSettings()
    /// What `myst.yml` contains; the difference to `draft` is what gets written.
    @State private var base = ProjectSettings()
    @State private var loaded = false
    @State private var writeTask: Task<Void, Never>?
    /// The text this view last wrote, to tell its own writes from undo and outside edits.
    @State private var lastWritten: String?
    @State private var bibFiles: [String] = []
    /// The bibliography files as typed, separated by commas.
    @State private var bibliographyText = ""
    /// The keywords as typed; split into the list when it changes.
    @State private var keywordsText = ""

    private var tab: SettingsTab { store.settingsTab ?? .project }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                tabBar
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        VStack(spacing: 20) { tabContent }
                            .frame(minWidth: 420, maxWidth: .infinity, alignment: .top)
                        sideColumn.frame(minWidth: 320, idealWidth: 400, maxWidth: 440)
                    }
                    VStack(spacing: 20) {
                        tabContent
                        sideColumn
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .frame(maxWidth: 1240, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color.mockupBackground)
        .onAppear(perform: load)
        .onDisappear(perform: flush)
        .onChange(of: project.configText) { configChanged() }
        .onChange(of: draft) { scheduleWrite() }
    }

    // MARK: Reading and writing

    private func load() {
        guard !loaded else { return }
        loaded = true
        base = ProjectSettings(yaml: project.configText)
        draft = base
        keywordsText = base.keywords.joined(separator: ", ")
        bibliographyText = base.bibliography.joined(separator: ", ")
        bibFiles = Self.files(withExtension: "bib", in: project.root)
    }

    private func configChanged() {
        if project.configText == lastWritten {
            return
        }
        // Undo, redo, or an edit of myst.yml elsewhere: show what the file says now.
        writeTask?.cancel()
        let parsed = ProjectSettings(yaml: project.configText)
        if parsed != base { base = parsed }
        if parsed != draft {
            draft = parsed
            keywordsText = parsed.keywords.joined(separator: ", ")
            bibliographyText = parsed.bibliography.joined(separator: ", ")
        }
    }

    private func scheduleWrite() {
        guard loaded, draft != base else { return }
        writeTask?.cancel()
        writeTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            write()
        }
    }

    private func flush() {
        guard writeTask != nil, draft != base else { return }
        writeTask?.cancel()
        write()
    }

    private func write() {
        writeTask = nil
        let themeChanged = draft.template != base.template
        if store.applySettings(draft, from: base, undoManager: undoManager) {
            lastWritten = store.project?.configText
            base = draft
            // A different theme is only picked up when the preview starts again.
            if themeChanged { store.build.restartPreview() }
        } else {
            draft = base
        }
    }

    // MARK: Layout

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Project settings")
                    .font(.system(size: 26, weight: .bold))
                Text("Settings of “\(project.title)” only. Changes are written straight to myst.yml (comments and key order are kept), except those marked as kept by JupyterBookNook.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Settings for All Projects…") { store.showAppSettings(.editor) }
                .help("Editor, templates and the MyST installation (⌘,)")
        }
    }

    private var tabBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                ForEach(SettingsTab.formTabs) { item in
                    Button {
                        flush()
                        store.settingsTab = item
                    } label: {
                        VStack(spacing: 7) {
                            Text(item.rawValue)
                                .fontWeight(item == tab ? .semibold : .regular)
                                .foregroundStyle(item == tab ? Color.primary : Color.secondary)
                            Rectangle()
                                .fill(item == tab ? Color.accentColor : .clear)
                                .frame(height: 2)
                        }
                        .fixedSize()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            Rectangle().fill(Color.mockupCardBorder).frame(height: 1)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .project: projectTab
        case .site: siteTab
        case .math: mathTab
        case .execution: executionTab
        case .exports: exportsTab
        case .bibliography, .plugins, .style: EmptyView() // screens of their own
        }
    }

    private var sideColumn: some View {
        VStack(spacing: 20) {
            TOCCard(project: project)
            YAMLCard(text: project.configText)
        }
    }

    // MARK: Project

    private var projectTab: some View {
        Group {
            SettingsCard("General") {
                LabeledField("Title") { TextField("", text: $draft.title, prompt: Text(project.root.lastPathComponent)) }
                LabeledField("Subtitle") { TextField("", text: $draft.subtitle, prompt: Text("e.g. Lecture notes, winter term")) }
                LabeledField("Authors") { AuthorChips(authors: $draft.authors) }
                HStack(alignment: .top, spacing: 18) {
                    LabeledField("License") { licensePicker }
                    LabeledField("GitHub repository") { TextField("", text: $draft.github, prompt: Text("owner/repository")) }
                }
                LabeledField("Bibliography", help: "Citation keys from \(draft.bibliography.count > 1 ? "these files" : "this file") are offered when you type {cite} or @.") {
                    HStack(spacing: 6) {
                        TextField("", text: $bibliographyText, prompt: Text("references.bib"))
                            .onChange(of: bibliographyText) {
                                draft.bibliography = bibliographyText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                            }
                        let unused = bibFiles.filter { !draft.bibliography.contains($0) }
                        if !unused.isEmpty {
                            Menu {
                                ForEach(unused, id: \.self) { file in
                                    Button(file) {
                                        bibliographyText = (draft.bibliography + [file]).joined(separator: ", ")
                                    }
                                }
                            } label: {
                                Image(systemName: "plus")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help(".bib files in the project")
                        }
                    }
                }
                LabeledField("Description") {
                    TextField("", text: $draft.description, prompt: Text("One or two sentences for search engines and link previews"), axis: .vertical)
                        .lineLimit(1...4)
                }
                LabeledField("Keywords", help: "Separated by commas.") {
                    TextField("", text: $keywordsText, prompt: Text("optimisation, calculus"))
                        .onChange(of: keywordsText) {
                            draft.keywords = keywordsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        }
                }
            }
            SettingsCard("Math macros") {
                MacrosEditor(macros: $draft.math)
            }
            SettingsCard("Editing this project") {
                Picker("Spelling", selection: Binding(get: { store.spellingLanguage }, set: { store.spellingLanguage = $0 })) {
                    Text("Automatic (detect the language)").tag("")
                    Divider()
                    ForEach(EditorSettingsView.languages, id: \.id) { language in
                        Text(language.name).tag(language.id)
                    }
                }
                AppSettingNote()
            }
            FoldersCard(project: project)
        }
    }

    @ViewBuilder
    private var licensePicker: some View {
        if draft.licenseIsStructured {
            Text("Separate content and code licences — edit in myst.yml")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        } else {
            Picker("", selection: $draft.license) {
                Text("None").tag("")
                ForEach(ProjectSettings.licenses, id: \.self) { Text($0).tag($0) }
                if !draft.license.isEmpty, !ProjectSettings.licenses.contains(draft.license) {
                    Text(draft.license).tag(draft.license)
                }
            }
            .labelsHidden()
            .controlSize(.large)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Site & theme

    private var siteTab: some View {
        Group {
            SettingsCard("Theme") {
                LabeledField("Theme", help: "book-theme has a table of contents on the left; article-theme suits a single long document.") {
                    Picker("", selection: $draft.template) {
                        Text("Default (book-theme)").tag("")
                        ForEach(ProjectSettings.templates, id: \.self) { Text($0).tag($0) }
                        if !draft.template.isEmpty, !ProjectSettings.templates.contains(draft.template) {
                            Text(draft.template).tag(draft.template)
                        }
                    }
                    .labelsHidden()
                }
            }
            SettingsCard("Logo and icon") {
                LabeledField("Logo") { FileField(path: $draft.logo, project: project, prompt: "images/logo.svg") }
                LabeledField("Logo in dark mode") { FileField(path: $draft.logoDark, project: project, prompt: "images/logo-dark.svg") }
                LabeledField("Text next to the logo") { TextField("", text: $draft.logoText, prompt: Text("Made with MyST (MyST's text when this is empty)")) }
                LabeledField("Favicon") { FileField(path: $draft.favicon, project: project, prompt: "images/favicon.ico") }
            }
            SettingsCard("Style") {
                HStack {
                    Text("Fonts, sizes and colours of the website are set in the style editor and written to \(project.stylesheet ?? DarkFigures.defaultStylesheet).")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Open Style Editor") { store.showSettings(.style) }
                }
            }
            SettingsCard("Dark mode") {
                Toggle("Invert SVG figures in dark mode", isOn: Binding(
                    get: { project.invertsSVGFiguresInDarkMode },
                    set: { store.setInvertsSVGFiguresInDarkMode($0, undoManager: undoManager) }
                ))
                Text("Black line drawings stay readable on the dark background; colours keep their hue. The rule is written into \(project.stylesheet ?? DarkFigures.defaultStylesheet) (site.options.style). A figure with :class: no-invert is left as it is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsCard("Layout") {
                Toggle("Hide the table of contents", isOn: $draft.hideTOC)
                Toggle("Hide the outline of each page", isOn: $draft.hideOutline)
                Toggle("Hide previous and next links", isOn: $draft.hideFooterLinks)
                Toggle("Hide the authors", isOn: $draft.hideAuthors)
                Toggle("Turn off search", isOn: $draft.hideSearch)
                Toggle("Use folder names in page URLs", isOn: $draft.folders)
            }
        }
    }

    // MARK: Math & numbering

    private var mathTab: some View {
        Group {
            SettingsCard("Math macros") {
                MacrosEditor(macros: $draft.math)
                Text("Available in every page, e.g. $\\R^n$ when \\R expands to \\mathbb{R}.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SettingsCard("Numbering") {
                Toggle("Number figures, equations, tables and code", isOn: $draft.numberingEnabled)
                Group {
                    Toggle("Headings (1, 1.1, 1.2, …)", isOn: $draft.numberHeadings)
                    Toggle("Figures", isOn: $draft.numberFigures)
                    Toggle("Equations", isOn: $draft.numberEquations)
                    Toggle("Tables", isOn: $draft.numberTables)
                    Toggle("Code blocks", isOn: $draft.numberCode)
                }
                .padding(.leading, 20)
                .disabled(!draft.numberingEnabled)
                if !draft.numberingOther.isEmpty {
                    Text("Further numbering settings in myst.yml are kept: \(draft.numberingOther.map(\.key).joined(separator: ", ")).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Execution

    private var executionTab: some View {
        Group {
            SettingsCard("Notebooks") {
                Toggle("Run notebook code when building and in the preview", isOn: Binding(
                    get: { store.build.executesNotebooks(project.root) },
                    set: { store.build.setExecutesNotebooks($0, for: project.root) }
                ))
                Text("MyST runs code cells with a Jupyter kernel (`myst build --execute`). Jupyter must be installed where MyST can find it, for example with `pip install jupyter-server ipykernel`. When this is off, the outputs saved in .ipynb files are shown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                AppSettingNote()
            }
            SettingsCard("MyST installation") {
                BookToolchainPicker(root: project.root)
                    .labelsHidden()
                Text("Which MyST builds and previews this project. Installations are set up in Settings › MyST.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                AppSettingNote()
            }
            SettingsCard("Cell outputs") {
                LabeledField("Error output (stderr)") { outputPicker($draft.outputStderr) }
                LabeledField("Standard output (stdout)") { outputPicker($draft.outputStdout) }
                Text("“warn” and “error” show the output and also report it in the build.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func outputPicker(_ selection: Binding<String>) -> some View {
        Picker("", selection: selection) {
            Text("Default (show)").tag("")
            ForEach(ProjectSettings.outputChoices, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
    }

    // MARK: Exports

    private var exportsTab: some View {
        Group {
            SettingsCard("HTML site") {
                Text("The static website, as visitors see it. Upload the folder to any web server or GitHub Pages.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Export HTML Site…") { store.isShowingExport = true }
                        .buttonStyle(.borderedProminent)
                    Button("Export as Zip…") { store.exportZip() }
                    Button("Reveal HTML in Finder") { store.revealBuild() }
                }
            }
            SettingsCard("Book documents") {
                Text("Documents made from the whole book (project.exports in myst.yml).")
                    .foregroundStyle(.secondary)
                ExportsEditor(exports: $draft.exports)
            }
            SettingsCard("Per-page documents") {
                PageExportsSettings(project: project)
            }
            HStack(alignment: .firstTextBaseline) {
                Button("Build Documents") {
                    flush()
                    store.buildDocuments()
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.build.isBuilding)
                Text("Builds the book documents and every page's documents. PDF needs LaTeX (typst needs Typst); Word and Markdown work without extra tools. Files go to _build/exports unless an output is given.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func files(withExtension ext: String, in root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        let base = root.standardizedFileURL.path + "/"
        var found: [String] = []
        for case let url as URL in enumerator {
            if ["_build", "node_modules"].contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            if url.pathExtension.lowercased() == ext {
                found.append(String(url.standardizedFileURL.path.dropFirst(base.count)))
            }
        }
        return found.sorted()
    }
}

// MARK: - Building blocks

/// A white card with a small uppercase title, as in the mockups.
/// Marks a setting of this app that is kept for the book but not written to myst.yml.
/// Where new pages, figures, downloads and plugins go; written to `.jupyterbooknook.yml`.
struct FoldersCard: View {
    @Environment(BookStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    let project: BookProject
    @State private var draft = BookFolders.defaults
    @FocusState private var focused: Bool

    var body: some View {
        SettingsCard("Folders for new files") {
            Text("New chapters, dropped files, pasted images and new plugins go into these folders, relative to the project folder (empty: the project folder itself). BibTeX and CSS files go into the project folder. Existing files are not moved.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                row("Pages", \.pages, default: BookFolders.defaults.pages)
                row("Figures", \.figures, default: BookFolders.defaults.figures)
                row("Downloads (PDFs, other files)", \.downloads, default: BookFolders.defaults.downloads)
                row("Plugins", \.plugins, default: BookFolders.defaults.plugins)
            }
            HStack {
                Label("Kept in \(BookFolders.fileName) in the project folder, not in myst.yml (MyST warns about keys it does not know)", systemImage: "folder")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                if project.folders != .defaults {
                    Button("Use Defaults") {
                        draft = .defaults
                        apply()
                    }
                    .controlSize(.small)
                }
            }
        }
        .onAppear { draft = project.folders }
        .onChange(of: project.folders) { draft = project.folders }
        .onChange(of: focused) { if !focused { apply() } }
        .onDisappear(perform: apply)
    }

    private func row(_ label: String, _ folder: WritableKeyPath<BookFolders, String>, default value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.primary.opacity(0.85))
            TextField("", text: $draft[dynamicMember: folder], prompt: Text("project folder"))
                .textFieldStyle(BoxedFieldStyle())
                .focused($focused)
                .onSubmit(apply)
                .help("Default: \(value)/")
        }
    }

    private func apply() {
        guard draft != project.folders else { return }
        store.setFolders(draft, undoManager: undoManager)
        // Refused (an invalid folder): show what is in effect again.
        if store.project?.folders != draft { draft = store.project?.folders ?? .defaults }
    }
}

struct AppSettingNote: View {
    var body: some View {
        Label("Kept by JupyterBookNook for this project, not in myst.yml", systemImage: "macwindow")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}

struct SettingsCard<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @ViewBuilder let accessory: Accessory

    init(_ title: String, @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.content = content()
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.8)
                Spacer()
                accessory
            }
            content
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mockupCard, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.mockupCardBorder))
    }
}

extension SettingsCard where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, content: content) { EmptyView() }
    }
}

/// A large text field with a light border, as in the mockups.
struct BoxedFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .boxed()
    }
}

extension View {
    /// The mockups' field look: padding, a rounded border and the text background.
    func boxed() -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 34)
            .background(Color.mockupCard, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.mockupFieldBorder))
    }
}

/// A label above its field, with an optional note below.
struct LabeledField<Content: View>: View {
    let label: String
    var help: String?
    @ViewBuilder let content: Content

    init(_ label: String, help: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.help = help
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.primary.opacity(0.85))
            content
                .textFieldStyle(BoxedFieldStyle())
            if let help {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A path inside the book, typed or chosen in an open panel.
struct FileField: View {
    @Binding var path: String
    let project: BookProject
    let prompt: String
    @State private var error: String?

    var body: some View {
        HStack {
            TextField("", text: $path, prompt: Text(prompt))
            Button("Choose…") { choose() }
        }
        if let error {
            Text(error).font(.caption).foregroundStyle(.red)
        } else if !path.isEmpty, !FileManager.default.fileExists(atPath: project.url(for: path).path), !path.contains("://") {
            Text("File not found in the project folder").font(.caption).foregroundStyle(.orange)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.directoryURL = project.root
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.message = "Choose an image inside the project folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let relative = project.relativePath(of: url) {
            path = relative
            error = nil
        } else {
            error = "Choose a file inside the project folder, so the site can include it."
        }
    }
}

/// Authors as chips ("Name · ORCID"); clicking one edits it in a popover.
struct AuthorChips: View {
    @Binding var authors: [ProjectSettings.Author]
    @State private var editing: ProjectSettings.Author.ID?

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach($authors) { $author in
                Button {
                    editing = author.id
                } label: {
                    Text(chipText(author))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .popover(isPresented: Binding(get: { editing == author.id }, set: { if !$0 { editing = nil } }), arrowEdge: .bottom) {
                    AuthorForm(author: $author) {
                        editing = nil
                        authors.removeAll { $0.id == author.id }
                    }
                }
            }
            Button("+ Add author") {
                let author = ProjectSettings.Author(name: "")
                authors.append(author)
                editing = author.id
            }
            .buttonStyle(.link)
            .padding(.vertical, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .boxed()
    }

    private func chipText(_ author: ProjectSettings.Author) -> String {
        let name = author.name.isEmpty ? "New author" : author.name
        return author.orcid.isEmpty ? name : name + " · ORCID"
    }
}

private struct AuthorForm: View {
    @Binding var author: ProjectSettings.Author
    let remove: () -> Void

    var body: some View {
        Form {
            TextField("Name", text: $author.name)
            TextField("Affiliation", text: $author.affiliation)
            TextField("ORCID", text: $author.orcid, prompt: Text("0000-0000-0000-0000"))
            TextField("Email", text: $author.email)
            HStack {
                Spacer()
                Button("Remove Author", role: .destructive, action: remove)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

/// Lays children out in rows, wrapping like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.indices + [index], needed, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

struct MacrosEditor: View {
    @Binding var macros: [ProjectSettings.Macro]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                Text("Macro").foregroundStyle(.secondary)
                Text("Expands to").foregroundStyle(.secondary)
                Color.clear.frame(width: 16, height: 1)
            }
            ForEach($macros) { $macro in
                GridRow {
                    TextField("", text: $macro.name, prompt: Text("\\R"))
                        .frame(width: 140)
                    TextField("", text: $macro.expansion, prompt: Text("\\mathbb{R}"))
                    RemoveButton { macros.removeAll { $0.id == macro.id } }
                }
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(BoxedFieldStyle())
            }
        }
        Button("+ Add macro") { macros.append(.init(name: "", expansion: "")) }
            .buttonStyle(.link)
    }
}

struct ExportsEditor: View {
    @Binding var exports: [ProjectSettings.Export]

    var body: some View {
        if exports.isEmpty {
            Text("No documents yet. Add one to build the book as a PDF or Word file.")
                .foregroundStyle(.secondary)
        }
        ForEach($exports) { $export in
            HStack(spacing: 6) {
                Picker("", selection: $export.format) {
                    ForEach(ProjectSettings.exportFormats, id: \.self) { Text($0).tag($0) }
                    if !ProjectSettings.exportFormats.contains(export.format) { Text(export.format).tag(export.format) }
                }
                .labelsHidden()
                .frame(width: 90)
                TextField("", text: $export.output, prompt: Text("Output, e.g. exports/book.\(Self.fileExtension(export.format))"))
                TextField("", text: $export.template, prompt: Text("Template (default)"))
                    .frame(width: 150)
                RemoveButton { exports.removeAll { $0.id == export.id } }
            }
            .textFieldStyle(BoxedFieldStyle())
        }
        Menu("+ Add document") {
            ForEach(ProjectSettings.exportFormats, id: \.self) { format in
                Button(format) { exports.append(.init(format: format)) }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    static func fileExtension(_ format: String) -> String {
        switch format {
        case "typst": return "pdf"
        case "tex": return "tex"
        default: return format
        }
    }
}

/// A list of strings with remove buttons, and an add menu offering `suggestions`.
struct StringListEditor: View {
    @Binding var items: [String]
    let placeholder: String
    let suggestions: [String]
    let addTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    TextField("", text: Binding(get: { items.indices.contains(i) ? items[i] : "" }, set: { if items.indices.contains(i) { items[i] = $0 } }),
                              prompt: Text(placeholder))
                    RemoveButton { if items.indices.contains(i) { items.remove(at: i) } }
                }
            }
            let unused = suggestions.filter { !items.contains($0) }
            if unused.isEmpty {
                Button("+ \(addTitle)") { items.append("") }
                    .buttonStyle(.link)
            } else {
                Menu("+ \(addTitle)") {
                    ForEach(unused, id: \.self) { file in
                        Button(file) { items.append(file) }
                    }
                    Divider()
                    Button("Other…") { items.append("") }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }
}

struct RemoveButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Remove")
    }
}

// MARK: - Side column

/// The table of contents as in myst.yml, with the files it leaves out.
struct TOCCard: View {
    @Environment(BookStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    let project: BookProject

    /// The row a drag is over.
    @State private var dropTarget: UUID?
    @State private var dragging: UUID?

    var body: some View {
        SettingsCard("Table of contents") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows(project.toc, depth: 0).enumerated()), id: \.element.entry.id) { index, row in
                    tocRow(row.entry, depth: row.depth, isRoot: index == 0)
                }
            }
            let loose = project.filesNotInTOC.filter { !store.ignoredFiles.contains($0) }
            if !loose.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if loose.count > 1 {
                        Text("\(loose.count) files are not in the table of contents:")
                    }
                    ForEach(loose, id: \.self) { path in
                        HStack(spacing: 5) {
                            if loose.count == 1 { Text("1 file is not in the table of contents:") }
                            Text(path).fontWeight(.semibold).lineLimit(1)
                            Text("—")
                            Button("Add") { store.addToBook(path, in: nil, undoManager: undoManager) }
                                .buttonStyle(.link)
                            Text("·")
                            Button("Ignore") { store.ignore(path) }
                                .buttonStyle(.link)
                        }
                    }
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }
            if !store.ignoredFiles.isEmpty {
                Button("Show \(store.ignoredFiles.count) ignored file\(store.ignoredFiles.count == 1 ? "" : "s") again") { store.unignoreAll() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        } accessory: {
            HStack(spacing: 6) {
                Button("+ Part") { store.isShowingNewPart = true }
                Button("+ Chapter") { store.presentNewChapter(in: nil) }
            }
            .controlSize(.small)
        }
    }

    private func tocRow(_ entry: TOCEntry, depth: Int, isRoot: Bool) -> some View {
        HStack(spacing: 10) {
            Text("⋮⋮")
                .font(.system(size: 13, weight: .bold))
                .kerning(-3)
                .foregroundStyle(.secondary.opacity(0.6))
                .help("Drag to move")
            if entry.isGroup {
                Text(project.displayTitle(for: entry)).fontWeight(.semibold)
            } else if let file = entry.file {
                Text(file)
                    .foregroundStyle(project.fileExists(file) ? Color.primary : Color.orange)
                    .help(project.fileExists(file) ? "Double-click to open \(file)" : "\(file) does not exist")
            } else {
                Text(project.displayTitle(for: entry)).foregroundStyle(.secondary)
            }
            Spacer()
            if dragging == entry.id {
                Text("dragging…").font(.caption).foregroundStyle(Color.accentColor)
            } else if isRoot {
                Text("root").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 10 + CGFloat(depth) * 22)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background {
            if dropTarget == entry.id || dragging == entry.id {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.accentColor.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if let file = entry.file, project.fileExists(file) { store.openFile(file) } }
        .draggable(SidebarDrag.entry(entry.id)) {
            Text(project.displayTitle(for: entry))
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .onAppear { dragging = entry.id }
                .onDisappear { dragging = nil }
        }
        .dropDestination(for: String.self) { items, _ in
            dropTarget = nil
            dragging = nil
            return store.drop(items, onto: entry, undoManager: undoManager)
        } isTargeted: { targeted in
            if targeted { dropTarget = entry.id } else if dropTarget == entry.id { dropTarget = nil }
        }
    }

    private func rows(_ entries: [TOCEntry], depth: Int) -> [(entry: TOCEntry, depth: Int)] {
        entries.flatMap { [($0, depth)] + rows($0.children, depth: depth + 1) }
    }
}

/// myst.yml as it is on disk, lightly highlighted.
struct YAMLCard: View {
    @Environment(BookStore.self) private var store
    let text: String

    var body: some View {
        SettingsCard("myst.yml (live)") {
            Text(Self.highlighted(text))
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Open as Text") { store.openConfigAsText() }
                .controlSize(.small)
        }
    }

    static func highlighted(_ yaml: String) -> AttributedString {
        var result = AttributedString()
        for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                var part = AttributedString(text)
                part.foregroundColor = .secondary
                result += part
            } else if let colon = keyColon(in: text) {
                var key = AttributedString(String(text[..<colon]))
                key.foregroundColor = .blue
                var rest = AttributedString(String(text[colon...]))
                rest.foregroundColor = Color(nsColor: .systemTeal)
                result += key + rest
            } else {
                var part = AttributedString(text)
                part.foregroundColor = Color(nsColor: .systemTeal)
                result += part
            }
            result += AttributedString("\n")
        }
        return result
    }

    /// The colon after a key (`  - file: x` → the colon after `file`).
    private static func keyColon(in line: String) -> String.Index? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        let bare = key.hasPrefix("- ") ? String(key.dropFirst(2)) : key
        guard !bare.isEmpty, !bare.contains(" ") || bare.hasPrefix("'") || bare.hasPrefix("\"") else { return nil }
        return colon
    }
}

extension Color {
    /// The colours of the mockups (Design/mockups/04): a cool light grey page with white cards.
    /// Dark mode uses the system colours.
    static let mockupBackground = dynamic(light: 0xF8F8FA, dark: .windowBackgroundColor)
    static let mockupCard = dynamic(light: 0xFFFFFF, dark: .textBackgroundColor)
    static let mockupCardBorder = dynamic(light: 0xE8E8EB, dark: .separatorColor)
    static let mockupFieldBorder = dynamic(light: 0xDADADE, dark: .separatorColor)

    private static func dynamic(light: UInt32, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            guard appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua else { return dark }
            return NSColor(srgbRed: CGFloat(light >> 16 & 0xFF) / 255, green: CGFloat(light >> 8 & 0xFF) / 255,
                           blue: CGFloat(light & 0xFF) / 255, alpha: 1)
        })
    }
}

/// The per-page part of the Exports tab: the switch and one checkbox per format for the whole book.
/// A checkbox is on when every page exports that format, off when none does, and mixed (−) when
/// some do. Clicking sets the format on all pages (mixed or off → on) or removes it (on → off).
/// Single pages are edited in the inspector.
struct PageExportsSettings: View {
    @Environment(BookStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    let project: BookProject

    var body: some View {
        @Bindable var store = store
        // Coverage is read from the pages' files; this redraws it after every change.
        let _ = store.fileRevision
        Toggle("Export pages separately", isOn: $store.pageExportsEnabled)
            .toggleStyle(.switch)
        Text("Each page can have its own PDF, Word, … documents, and offer files made elsewhere (e.g. slides) for download. They are written into the page's front matter; the inspector (⌥⌘0) shows and edits them for the open page.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if store.pageExportsEnabled {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(ProjectSettings.exportFormats, id: \.self) { format in
                    let coverage = store.coverage(of: format)
                    MixedCheckbox(title: PageExports.title(of: format), state: coverage) {
                        store.setFormat(format, onAllPages: coverage != .all, undoManager: undoManager)
                    }
                    .help(help(for: coverage))
                    .fixedSize()
                }
            }
            Text("− means some pages have it. New pages get the formats that are on for all pages.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func help(for coverage: BookStore.Coverage) -> String {
        switch coverage {
        case .all: return "Every page has it. Click to remove it from all pages."
        case .some: return "Some pages have it. Click to add it to all pages."
        case .none: return "No page has it. Click to add it to all pages."
        }
    }
}

/// A native checkbox with a mixed state. The click is reported, and the shown state always follows
/// `state` (the button's own cycling is not used).
struct MixedCheckbox: NSViewRepresentable {
    let title: String
    let state: BookStore.Coverage
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        button.allowsMixedState = true
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.title = title
        button.state = switch state {
        case .all: .on
        case .some: .mixed
        case .none: .off
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func clicked(_ sender: NSButton) { action() }
    }
}
