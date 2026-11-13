import AppKit
import BookModel
import SwiftUI

/// The ⌘T overlay: type to filter, ↑ ↓ to choose, ↵ to insert at the cursor, esc to close.
struct SnippetPicker: View {
    @Environment(BookStore.self) private var store
    @State private var query = ""
    @State private var selectedID: PageTemplate.ID?
    @State private var templates: [PageTemplate] = []
    @FocusState private var searchFocused: Bool

    private var filtered: [PageTemplate] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return templates }
        return templates.filter { $0.name.lowercased().contains(q) || $0.summary.lowercased().contains(q) }
    }

    private var selected: PageTemplate? {
        filtered.first { $0.id == selectedID } ?? filtered.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "text.badge.plus")
                    .foregroundStyle(.secondary)
                TextField("Insert snippet…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($searchFocused)
                    .onSubmit(insert)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.tab) { move(1); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                Button("Edit Templates…") { store.showAppSettings(.templates) }
                .buttonStyle(.link)
                .font(.caption)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(PageTemplate.Kind.allCases, id: \.self) { kind in
                                let items = filtered.filter { $0.kind == kind }
                                if !items.isEmpty {
                                    Text(kind.rawValue.uppercased())
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 12)
                                        .padding(.top, 10)
                                        .padding(.bottom, 4)
                                    ForEach(items) { template in
                                        row(template).id(template.id)
                                    }
                                }
                            }
                            if filtered.isEmpty {
                                Text("No snippet matches “\(query)”")
                                    .foregroundStyle(.secondary)
                                    .padding(16)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .onChange(of: selectedID) { if let selectedID { proxy.scrollTo(selectedID) } }
                }
                .frame(width: 250)
                Divider()
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(height: 320)
            Divider()
            Text("↵ insert · ↑↓ choose · esc close — {{selection}} wraps the selected text")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
        }
        .frame(width: 640)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .onAppear {
            templates = TemplateLibrary.templates(.snippet, projectRoot: nil) + TemplateLibrary.templates(.page, projectRoot: nil)
            searchFocused = true
        }
        .onChange(of: query) { selectedID = filtered.first?.id }
    }

    private func row(_ template: PageTemplate) -> some View {
        let isSelected = template.id == selected?.id
        return HStack {
            Text(template.name)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
            Spacer()
            if template.source != .builtIn {
                Text(template.source == .project ? "book" : "yours")
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            selectedID = template.id
            insert()
        }
        .onTapGesture { selectedID = template.id }
    }

    @ViewBuilder
    private var preview: some View {
        if let template = selected {
            VStack(alignment: .leading, spacing: 8) {
                if !template.summary.isEmpty {
                    Text(template.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ScrollView {
                    Text(template.insertion(selection: "", values: store.templateValues(for: store.currentPath)).text)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(14)
        }
    }

    private func move(_ offset: Int) {
        let items = PageTemplate.Kind.allCases.flatMap { kind in filtered.filter { $0.kind == kind } }
        guard !items.isEmpty else { return }
        let index = items.firstIndex { $0.id == selected?.id } ?? 0
        selectedID = items[(index + offset + items.count) % items.count].id
    }

    private func insert() {
        guard let template = selected else { return }
        store.insertSnippet(template)
    }

    private func close() {
        store.isShowingSnippets = false
        if let textView = store.editorTextView { textView.window?.makeFirstResponder(textView) }
    }
}
