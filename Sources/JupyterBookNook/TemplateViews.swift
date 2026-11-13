import AppKit
import BookModel
import SwiftUI

/// Settings › Templates: snippets for ⌘T and page templates for New Chapter, the same for every book,
/// edited in place. Built-in templates can be changed too; the change is saved as your own copy,
/// which replaces the built-in one until you restore it.
struct TemplateEditorView: View {
    @Environment(BookStore.self) private var store

    @State private var templates: [PageTemplate] = []
    @State private var selectedID: PageTemplate.ID?
    /// The template as edited; saved shortly after typing stops.
    @State private var draft: PageTemplate?
    /// The template as last loaded or saved.
    @State private var original: PageTemplate?
    @State private var saveTask: Task<Void, Never>?
    @State private var problem: String?
    @State private var savingBook = false

    /// The list and the first selection are set up here, not on appear: changing them while the
    /// list lays out makes AppKit warn about reentrant table updates.
    init() {
        let all = Self.load()
        _templates = State(initialValue: all)
        _selectedID = State(initialValue: all.first?.id)
        _original = State(initialValue: all.first)
        _draft = State(initialValue: all.first)
    }

    /// Built-in and your own templates; templates kept inside a book are not used any more.
    private static func load() -> [PageTemplate] {
        TemplateLibrary.templates(.snippet, projectRoot: nil) + TemplateLibrary.templates(.page, projectRoot: nil)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 270)
            Divider()
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onDisappear(perform: flush)
        .onChange(of: draft) { scheduleSave() }
        // Selection changes go through onChange, not the binding, so the table is not changed
        // from inside its own delegate callback.
        .onChange(of: selectedID) { if selectedID != original?.id { select(selectedID) } }
        .sheet(isPresented: $savingBook) {
            SaveTemplateSheet(kind: .book, suggestedName: store.project?.title ?? "") { name, _ in
                store.saveBookAsTemplate(name: name)
            }
        }
    }

    // MARK: List

    private var sidebar: some View {
        VStack(spacing: 0) {
            if let project = store.project, !bookTemplates.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("“\(project.title)” has \(bookTemplates.count) template\(bookTemplates.count == 1 ? "" : "s") of its own (.nook/templates), which are no longer used.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Move to Your Templates") { moveBookTemplates(project) }
                        .controlSize(.small)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12))
                Divider()
            }
            List(selection: $selectedID) {
                ForEach(PageTemplate.Kind.allCases, id: \.self) { kind in
                    Section(kind == .snippet ? "Snippets (⌘T)" : "Page templates (New Chapter)") {
                        ForEach(templates.filter { $0.kind == kind }) { template in
                            HStack {
                                Text(template.name)
                                Spacer()
                                if let badge = badge(for: template) {
                                    Text(badge).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .tag(template.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
                Menu {
                    Button("New Snippet") { create(.snippet, body: "{{cursor}}{{selection}}\n") }
                    Button("New Page Template") { create(.page, body: "# {{title}}\n\n{{cursor}}") }
                    if let document = store.currentDocument {
                        Divider()
                        Button("New Page Template from \(document.fileName)") { create(.page, body: document.text, name: store.project?.pageTitles[document.path]) }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New template")
                Spacer()
                Menu("Folders") {
                    Button("Your Snippets") { Self.reveal(TemplateLibrary.userSnippetsFolder) }
                    Button("Your Page Templates") { Self.reveal(TemplateLibrary.userPagesFolder) }
                    Divider()
                    Button("Your Book Templates") { Self.reveal(TemplateLibrary.userBooksFolder) }
                    Button("Save the Open Book as a Book Template…") { savingBook = true }
                        .disabled(store.project == nil)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func badge(for template: PageTemplate) -> String? {
        if template.overridesBuiltIn { return "edited" }
        switch template.source {
        case .builtIn: return nil
        case .user: return "yours"
        case .project: return "book"
        }
    }

    // MARK: Editor

    @ViewBuilder
    private var editor: some View {
        if let binding = Binding($draft) {
            VStack(alignment: .leading, spacing: 14) {
                LabeledField("Name") { TextField("", text: binding.name) }
                LabeledField("Description") { TextField("", text: binding.summary, prompt: Text("Shown in the list")) }
                VStack(alignment: .leading, spacing: 5) {
                    Text(binding.wrappedValue.kind == .snippet ? "Snippet" : "Page")
                    TextEditor(text: binding.body)
                        .font(.system(size: 13, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color.mockupCard, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.mockupFieldBorder))
                        .autocorrectionDisabled()
                    Text(placeholderHelp(binding.wrappedValue.kind))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    } else {
                        Text(status(binding.wrappedValue)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let url = original?.url {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    if original?.overridesBuiltIn == true {
                        Button("Restore Built-in") { remove() }
                    } else if original?.source != .builtIn {
                        Button("Delete", role: .destructive) { remove() }
                    }
                }
                .font(.callout)
            }
            .padding(24)
        } else {
            Text("Choose a template")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func placeholderHelp(_ kind: PageTemplate.Kind) -> String {
        let common = "{{title}} the page title, {{label}} the title as a label, {{author}}, {{book}}, {{date}}."
        return kind == .snippet
            ? "{{cursor}} puts the cursor there, {{cursor:text}} inserts text selected; {{2:text}}, {{3}}, … are further stops for ⇥; {{selection}} is replaced by the selected text. " + common
            : "Filled in when New Chapter creates the page: " + common
    }

    private func status(_ template: PageTemplate) -> String {
        if template.source == .builtIn { return "Built in — your changes are saved as your own copy." }
        if template.overridesBuiltIn { return "Your copy replaces the built-in template. Saved automatically." }
        return "Saved automatically."
    }

    // MARK: Actions

    private func reload(select id: PageTemplate.ID?) {
        templates = Self.load()
        select(id ?? selectedID ?? templates.first?.id)
    }

    private func select(_ id: PageTemplate.ID?) {
        flush()
        selectedID = id
        original = templates.first { $0.id == id }
        draft = original
        problem = nil
    }

    private func scheduleSave() {
        guard let draft, draft != original || draft.source != original?.source else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func flush() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        save()
    }

    private func save() {
        saveTask = nil
        guard var template = draft, let original else { return }
        guard template.name.trimmingCharacters(in: .whitespaces).isEmpty == false else {
            problem = "A template needs a name."
            return
        }
        if template.source == .builtIn { template.source = .user }
        let clash = templates.contains {
            $0.id != original.id && $0.kind == template.kind && $0.name == template.name && $0.source == template.source
        }
        guard !clash else {
            problem = "“\(template.name)” already exists there."
            return
        }
        do {
            let saved = try TemplateLibrary.save(template, replacing: original.url == nil ? nil : original, projectRoot: nil)
            problem = nil
            let id = saved.id
            templates = Self.load()
            selectedID = id
            self.original = templates.first { $0.id == id } ?? saved
            // Keep what is being typed; only the file and source change.
            draft?.source = saved.source
            draft?.url = saved.url
            draft?.overridesBuiltIn = self.original?.overridesBuiltIn ?? false
            if draft == self.original { self.draft = self.original }
        } catch {
            problem = error.localizedDescription
        }
    }

    private func create(_ kind: PageTemplate.Kind, body: String, name: String? = nil) {
        flush()
        let existing = Set(templates.filter { $0.kind == kind }.map(\.name))
        var candidate = name ?? (kind == .snippet ? "New snippet" : "New page")
        var n = 2
        let base = candidate
        while existing.contains(candidate) { candidate = "\(base) \(n)"; n += 1 }
        let template = PageTemplate(name: candidate, summary: "", body: body, source: .user, kind: kind)
        do {
            let saved = try TemplateLibrary.save(template, replacing: nil, projectRoot: nil)
            reload(select: saved.id)
        } catch {
            problem = error.localizedDescription
        }
    }

    private func remove() {
        saveTask?.cancel()
        saveTask = nil
        guard let original else { return }
        do {
            try TemplateLibrary.delete(original)
        } catch {
            problem = error.localizedDescription
            return
        }
        let id = original.overridesBuiltIn ? original.id : nil
        self.original = nil
        draft = nil
        reload(select: id ?? templates.first?.id)
    }

    /// Templates kept inside the open book from earlier versions.
    private var bookTemplates: [PageTemplate] {
        store.project.map { TemplateLibrary.bookTemplates(projectRoot: $0.root) } ?? []
    }

    private func moveBookTemplates(_ project: BookProject) {
        flush()
        do {
            try TemplateLibrary.moveBookTemplatesToUser(projectRoot: project.root, bookName: project.title)
            reload(select: selectedID)
        } catch {
            problem = error.localizedDescription
        }
    }

    static func reveal(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}

struct SaveTemplateSheet: View {
    enum Kind { case book }

    @Environment(\.dismiss) private var dismiss
    let kind: Kind
    let suggestedName: String
    let save: (_ name: String, _ inBook: Bool) -> Void
    @State private var name = ""
    @State private var inBook = false

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Name", text: $name)
                if kind == .book {
                    Text("Copies the book’s files (without _build) into your book templates.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save(trimmed, inBook)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmed.isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 440)
        .onAppear { name = suggestedName }
    }
}

/// Project › New Project: the project's folder (new or existing), a template, a title and an author
/// (mockup style). For a folder that already has myst.yml the template is not used and the title
/// starts as the project's own. The folders for pages, figures, downloads and plugins are added
/// where missing.
struct NewProjectSheet: View {
    @Environment(BookStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var templates = TemplateLibrary.projectTemplates()
    @State private var template: ProjectTemplate.ID = TemplateLibrary.builtInProjects[0].id
    @State private var title = ""
    /// From Settings › Editor › New projects; empty unless set there.
    @State private var author = EditorSettings.shared.defaultAuthor
    /// The folder chosen with Choose…; until then a new folder in Documents named after the title.
    @State private var chosen: URL?
    /// The title in the chosen folder's myst.yml, when it already is a project.
    @State private var existingTitle: String?

    init(folder: URL? = nil) {
        _chosen = State(initialValue: folder)
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespaces) }
    private var folder: URL? {
        if let chosen { return chosen }
        guard !trimmedTitle.isEmpty else { return nil }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(BookSlug.fileName(for: trimmedTitle), isDirectory: true)
    }
    private var isProject: Bool {
        folder.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(BookProject.configFileName).path) } ?? false
    }
    private var hasFiles: Bool {
        guard let folder else { return false }
        return !((try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { !$0.hasPrefix(".") }.isEmpty ?? true)
    }
    private var folderNames: String {
        let names = (folder.map(BookProject.readFolders(in:)) ?? .defaults).all.map { $0 + "/" }
        return names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names.last! : names.joined()
    }

    private var summary: String {
        guard let folder else { return "Choose the project’s folder, or type a title for a new folder in Documents." }
        if isProject { return "\(folder.path) already is a project: the folders \(folderNames) are added where missing, then it opens." }
        if hasFiles { return "Adds myst.yml, the template’s pages and the folders \(folderNames) to \(folder.path). Files already there are kept." }
        return "Creates \(folder.path) with myst.yml, the template’s pages and the folders \(folderNames)."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Project").font(.title2.weight(.semibold))
                Text("Sets up a folder as a Jupyter Book project, then opens it.")
                    .foregroundStyle(.secondary)
            }
            LabeledField("Folder", help: summary) {
                HStack {
                    Text(folder?.path ?? "A new folder in Documents")
                        .foregroundStyle(folder == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…") { chooseFolder() }
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(templates) { item in
                    Button { template = item.id } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: item.symbol)
                                .font(.title2)
                                .foregroundStyle(.tint)
                            Text(item.name).fontWeight(.semibold)
                            Text(item.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9)
                                .strokeBorder(item.id == template ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: item.id == template ? 2 : 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .disabled(isProject)
            .opacity(isProject ? 0.45 : 1)
            .help(isProject ? "The folder already has a myst.yml: its files are kept and no template is used." : "")
            LabeledField("Title", help: isProject ? "The project’s title in myst.yml; a new one is written there." : nil) {
                TextField("", text: $title, prompt: Text(chosen?.lastPathComponent ?? "e.g. Optimisation Notes"))
            }
            LabeledField("Author") { TextField("", text: $author) }
                .disabled(isProject)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isProject ? "Add Folders and Open" : "Create") {
                    guard let folder, let chosenTemplate = templates.first(where: { $0.id == template }) else { return }
                    let name = trimmedTitle.isEmpty ? (existingTitle ?? folder.lastPathComponent) : trimmedTitle
                    dismiss()
                    store.createProject(chosenTemplate, at: folder, values: TemplateValues(title: name, author: author, book: name),
                                        retitle: isProject && name != existingTitle ? name : nil)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(folder == nil)
            }
        }
        .padding(24)
        .frame(width: 620)
        .onAppear { if let chosen, existingTitle == nil { use(chosen) } }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = chosen ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        panel.prompt = "Choose"
        panel.message = "The project’s folder: a new one (New Folder), an empty one, or one that already has files or a myst.yml"
        if panel.runModal() == .OK, let url = panel.url { use(url) }
    }

    /// Takes a chosen folder; an existing project's title fills the title field.
    private func use(_ url: URL) {
        let previous = existingTitle
        chosen = url
        existingTitle = (try? BookProject(root: url))?.title
        if let existingTitle { title = existingTitle } else if title == previous { title = "" }
    }
}
