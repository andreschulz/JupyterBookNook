import AppKit
import BookModel
import ProjectIndex
import SwiftUI

/// Bibliography (sidebar › Bibliography): every entry of the book's BibTeX files with authors and
/// title. Double-click edits an entry; edits are written into its .bib file as one undo step.
struct BibliographyView: View {
    @Environment(BookStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    let project: BookProject

    @State private var records: [BibRecord] = []
    @State private var selection: BibRecord.ID?
    @State private var query = ""
    @State private var sortOrder = [KeyPathComparator(\Row.authors)]
    @State private var editing: EditRequest?

    /// The sheet: an existing entry, or a new one for a file.
    struct EditRequest: Identifiable {
        let id = UUID()
        var record: BibRecord
        var originalKey: String?
    }

    struct Row: Identifiable {
        let record: BibRecord
        var id: String { record.id }
        var key: String { record.key }
        var authors: String { record.authorNames }
        var title: String { record["title"] ?? "" }
        var year: String { record["year"] ?? "" }
        var file: String { record.file }
    }

    private var rows: [Row] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = records.map(Row.init)
        let filtered = q.isEmpty ? all : all.filter {
            "\($0.key) \($0.authors) \($0.title) \($0.year)".lowercased().contains(q)
        }
        return filtered.sorted(using: sortOrder)
    }

    var body: some View {
        // Entries are read from the files; this re-reads them after every change.
        let _ = store.fileRevision
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bibliography").font(.system(size: 26, weight: .bold))
                    Text(subtitle).foregroundStyle(.secondary)
                }
                Spacer()
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            // The site's only citation setting (book and article theme, mystmd 1.11).
            HStack(spacing: 8) {
                Picker("Citations on the website", selection: Binding(
                    get: { project.configValue(["site", "options", "numbered_references"])?.lowercased() == "true" },
                    set: { numbered in
                        store.setConfigValue(["site", "options", "numbered_references"], to: numbered ? .plain("true") : nil,
                                             summary: numbered ? "Numbered citations" : "Author–year citations", undoManager: undoManager)
                    }
                )) {
                    Text("Author–year: (Nocedal & Wright, 2006)").tag(false)
                    Text("Numbered: [1]").tag(true)
                }
                .fixedSize()
                Text("site.options.numbered_references · PDF and LaTeX exports use the style of their template.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Numbering applies to parenthetical citations. A LaTeX template sets its own style (natbib or biblatex) in its template.yml.")
            }
            if project.bibFiles.isEmpty {
                ContentUnavailableView {
                    Label("No BibTeX file", systemImage: "books.vertical")
                } description: {
                    Text("Drag a .bib file onto the sidebar, or create references.bib here. It is added to myst.yml, so {cite} and @ find its keys.")
                } actions: {
                    Button("Create references.bib") { createFile() }
                }
            } else {
                Table(rows, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Authors", value: \.authors) { Text($0.authors).lineLimit(1) }
                        .width(min: 120, ideal: 200)
                    TableColumn("Title", value: \.title) { Text($0.title).lineLimit(1) }
                        .width(min: 160, ideal: 360)
                    TableColumn("Year", value: \.year) { Text($0.year) }
                        .width(50)
                    TableColumn("Key", value: \.key) { Text($0.key).font(.system(.body, design: .monospaced)) }
                        .width(min: 90, ideal: 140)
                    TableColumn("File", value: \.file) { Text($0.file).foregroundStyle(.secondary) }
                        .width(min: 80, ideal: 120)
                }
                .contextMenu(forSelectionType: BibRecord.ID.self) { ids in
                    if let record = ids.first.flatMap(record(for:)) {
                        Button("Edit…") { edit(record) }
                        Button("Copy {cite}`\(record.key)`") { copy("{cite}`\(record.key)`") }
                        Divider()
                        Button("Delete", role: .destructive) { store.saveBibRecord(nil, replacing: record.key, in: record.file, undoManager: undoManager) }
                    }
                } primaryAction: { ids in
                    if let record = ids.first.flatMap(record(for:)) { edit(record) }
                }
                .onDeleteCommand {
                    if let record = selection.flatMap(record(for:)) {
                        store.saveBibRecord(nil, replacing: record.key, in: record.file, undoManager: undoManager)
                    }
                }
                HStack {
                    Menu("New Entry") {
                        ForEach(project.bibFiles, id: \.self) { file in
                            Button(project.bibFiles.count > 1 ? "In \(file)" : "New Entry") { newEntry(in: file) }
                        }
                    } primaryAction: {
                        newEntry(in: project.bibFiles[0])
                    }
                    .fixedSize()
                    Button("Edit…") { if let record = selection.flatMap(record(for:)) { edit(record) } }
                        .disabled(selection == nil)
                    Spacer()
                    Text("Double-click an entry to edit it.").font(.caption).foregroundStyle(.secondary)
                    Button("Show in Finder") {
                        let file = selection.flatMap(record(for:))?.file ?? project.bibFiles[0]
                        NSWorkspace.shared.activateFileViewerSelecting([project.url(for: file)])
                    }
                }
            }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.mockupBackground)
        .onAppear(perform: reload)
        .onChange(of: store.fileRevision) { reload() }
        .sheet(item: $editing) { request in
            BibEntryEditor(record: request.record, isNew: request.originalKey == nil) { record in
                store.saveBibRecord(record, replacing: request.originalKey, in: record.file, undoManager: undoManager)
            }
        }
    }

    private var subtitle: String {
        let files = project.bibFiles
        let count = "\(records.count) entr\(records.count == 1 ? "y" : "ies")"
        return files.isEmpty ? "References for {cite} and @" : "\(count) in \(files.joined(separator: ", "))"
    }

    private func reload() {
        records = store.bibRecords()
    }

    private func record(for id: BibRecord.ID) -> BibRecord? {
        records.first { $0.id == id }
    }

    private func edit(_ record: BibRecord) {
        editing = EditRequest(record: record, originalKey: record.key)
    }

    private func newEntry(in file: String) {
        let fields = BibRecord.suggestedFields(for: "article").prefix(4).map { BibRecord.Field(name: $0, value: "") }
        editing = EditRequest(record: BibRecord(type: "article", key: "", fields: Array(fields), file: file), originalKey: nil)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func createFile() {
        let url = project.url(for: "references.bib")
        do {
            try "".write(to: url, atomically: true, encoding: .utf8)
            store.addUnlistedBibliographies(undoManager: undoManager)
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }
}

/// The edit dialog for one BibTeX entry: type, key and fields, with the BibTeX it will write.
struct BibEntryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var record: BibRecord
    let isNew: Bool
    let save: (BibRecord) -> Bool

    private var keyIsValid: Bool {
        let key = record.key.trimmingCharacters(in: .whitespaces)
        return !key.isEmpty && !key.contains(where: { $0.isWhitespace || ",{}".contains($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New Entry" : "Edit Entry").font(.title2.weight(.semibold))
            HStack(alignment: .top, spacing: 14) {
                LabeledField("Type") {
                    Picker("", selection: $record.type) {
                        ForEach(BibRecord.types, id: \.self) { Text($0).tag($0) }
                        if !BibRecord.types.contains(record.type) { Text(record.type).tag(record.type) }
                    }
                    .labelsHidden()
                }
                .frame(width: 180)
                LabeledField("Key", help: "Cite it as {cite}`\(record.key.isEmpty ? "key" : record.key)` or @\(record.key.isEmpty ? "key" : record.key).") {
                    TextField("", text: $record.key, prompt: Text("nocedal2006"))
                        .font(.system(.body, design: .monospaced))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Fields")
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                        ForEach($record.fields) { $field in
                            GridRow {
                                TextField("", text: $field.name, prompt: Text("field"))
                                    .font(.system(.body, design: .monospaced))
                                    .frame(width: 120)
                                TextField("", text: $field.value, prompt: Text(placeholder(for: field.name)), axis: .vertical)
                                    .lineLimit(1...4)
                                RemoveButton { record.fields.removeAll { $0.id == field.id } }
                            }
                            .textFieldStyle(BoxedFieldStyle())
                        }
                    }
                }
                .frame(minHeight: 160, maxHeight: 320)
                HStack {
                    let missing = BibRecord.suggestedFields(for: record.type).filter { name in !record.fields.contains { $0.name.lowercased() == name } }
                    Menu("+ Add field") {
                        ForEach(missing, id: \.self) { name in
                            Button(name) { record.fields.append(.init(name: name, value: "")) }
                        }
                        Divider()
                        Button("Other") { record.fields.append(.init(name: "", value: "")) }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Spacer()
                }
            }
            DisclosureGroup("BibTeX") {
                Text(record.text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Text(record.file).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    var cleaned = record
                    cleaned.key = record.key.trimmingCharacters(in: .whitespaces)
                    cleaned.fields = record.fields.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty && !$0.value.isEmpty }
                    if save(cleaned) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!keyIsValid)
            }
        }
        .padding(24)
        .frame(width: 620)
    }

    private func placeholder(for field: String) -> String {
        switch field.lowercased() {
        case "author": return "Last, First and Last, First"
        case "year": return "2024"
        case "doi": return "10.1000/xyz123"
        case "pages": return "1--10"
        default: return ""
        }
    }
}
