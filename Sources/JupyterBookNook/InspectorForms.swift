import BookModel
import MystSyntax
import SwiftUI

/// Inspector › Page: common front matter fields of the open page. Each change is written into the
/// page's front matter through the editor, so ⌘Z undoes it like typing.
struct PageInfoSection: View {
    @Environment(BookStore.self) private var store
    let document: OpenDocument

    private static let fields: [(key: String, title: String, help: String)] = [
        ("title", "Title", "Overrides the first heading as the page's title"),
        ("short_title", "Short title", "Shown in the table of contents and navigation"),
        ("subtitle", "Subtitle", ""),
        ("label", "Label", "Lets other pages link here with {ref} or [](#label)"),
        ("date", "Date", "e.g. 2026-10-26"),
        ("keywords", "Keywords", "Separated by commas"),
        ("description", "Description", "For search engines and link previews"),
    ]

    var body: some View {
        let heading = document.headings.first?.title ?? ""
        ForEach(Self.fields, id: \.key) { field in
            CommitField(title: field.title, value: value(field.key), placeholder: field.key == "title" ? heading : "") { text in
                write(field.key, text)
            }
            .help(field.help)
        }
    }

    private func value(_ key: String) -> String {
        switch FrontMatter.value(at: [key], in: document.text) {
        case .string(let text), .plain(let text): return text
        case .list(let items): return items.compactMap { if case .string(let s) = $0 { s } else if case .plain(let s) = $0 { s } else { nil } }.joined(separator: ", ")
        default: return ""
        }
    }

    private func write(_ key: String, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let value: YAMLValue?
        if trimmed.isEmpty {
            value = nil
        } else if key == "keywords" {
            value = .list(trimmed.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 != .string("") })
        } else {
            value = .string(trimmed)
        }
        let title = Self.fields.first { $0.key == key }?.title ?? key
        store.editCurrentPage(value == nil ? "Remove \(title)" : "Set \(title)") { try FrontMatter.setting([key], to: value, in: $0) }
    }
}

/// Inspector › Directive: the directive around the cursor, with its argument and options as fields.
struct DirectiveSection: View {
    @Environment(BookStore.self) private var store
    let block: DirectiveBlock

    private var entry: MystCatalog.Entry? {
        store.index.directive(block.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("{\(block.name)}").font(.system(.body, design: .monospaced).weight(.semibold))
            if let entry {
                Text(entry.summary).font(.caption).foregroundStyle(.secondary)
            }
        }
        CommitField(title: argumentTitle, value: block.argument, placeholder: "") { text in
            store.editCurrentPage("Change {\(block.name)}") { block.settingArgument(text, in: $0) }
        }
        ForEach(block.options, id: \.key) { option in
            HStack(alignment: .bottom, spacing: 4) {
                CommitField(title: option.key, value: option.value, placeholder: "", monospacedTitle: true) { text in
                    store.editCurrentPage("Change :\(option.key):") { block.settingOption(option.key, to: text, in: $0) }
                }
                RemoveButton {
                    store.editCurrentPage("Remove :\(option.key):") { block.settingOption(option.key, to: nil, in: $0) }
                }
                .padding(.bottom, 4)
            }
        }
        let missing = (entry?.options ?? []).filter { block.option($0) == nil }
        Menu("Add Option") {
            ForEach(missing, id: \.self) { key in
                Button(key) {
                    store.editCurrentPage("Add :\(key):") { block.settingOption(key, to: Self.defaultValue(key, block: block), in: $0) }
                }
            }
            if !missing.isEmpty { Divider() }
            Button("Other…") { store.revealDirectiveOptions(block) }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Adds the option below the directive's other options")
    }

    private var argumentTitle: String {
        switch block.name {
        case "figure", "image", "include", "literalinclude", "iframe": return "Source"
        case "code", "code-block", "code-cell": return "Language"
        case "embed", "solution": return "Target label"
        default: return "Title"
        }
    }

    /// A sensible start for a new option: a label from the directive and its argument, flags empty.
    static func defaultValue(_ key: String, block: DirectiveBlock) -> String {
        switch key {
        case "label":
            let prefix = ["figure": "fig", "image": "fig", "table": "tbl", "list-table": "tbl", "csv-table": "tbl",
                          "math": "eq", "code": "code", "code-block": "code", "exercise": "ex"][block.name] ?? block.name.replacingOccurrences(of: "prf:", with: "")
            let stem = ((block.argument as NSString).lastPathComponent as NSString).deletingPathExtension
            let slug = BookProject.slug(for: stem.isEmpty ? "name" : stem)
            return "\(prefix)-\(slug.isEmpty ? "name" : slug)"
        case "width": return "80%"
        case "align": return "center"
        case "class": return block.name == "dropdown" || block.name == "solution" ? "dropdown" : ""
        case "open", "linenos", "nonumber", "hidden", "selected", "enumerated", "literal": return ""
        default: return ""
        }
    }
}

/// A labelled text field that writes its value when Return is pressed or the field loses focus.
struct CommitField: View {
    let title: String
    let value: String
    var placeholder: String
    var monospacedTitle = false
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(monospacedTitle ? .caption.monospaced() : .caption)
                .foregroundStyle(.secondary)
            TextField("", text: $text, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(save)
        }
        .onAppear { text = value }
        .onChange(of: value) { if !focused { text = value } }
        .onChange(of: focused) { if !focused { save() } }
    }

    private func save() {
        if text != value { commit(text) }
    }
}
