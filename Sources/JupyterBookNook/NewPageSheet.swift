import BookModel
import SwiftUI

/// Sheet for "New Chapter…" and "New Part…". The file and the myst.yml entry are created together.
struct NewPageSheet: View {
    enum Kind {
        case chapter, part
    }

    @Environment(\.dismiss) private var dismiss
    let kind: Kind
    let project: BookProject
    let initialPart: UUID?
    let create: (_ title: String, _ part: UUID?, _ template: PageTemplate?) -> Void

    @State private var title = ""
    @State private var part: UUID?
    @State private var templates: [PageTemplate] = []
    @AppStorage("newPage.template") private var templateID = TemplateLibrary.builtInPages[0].id

    private var template: PageTemplate? {
        templates.first { $0.id == templateID } ?? templates.first
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Title", text: $title, prompt: Text(kind == .chapter ? "e.g. Gradient Descent" : "e.g. Part I · Foundations"))
                    if kind == .chapter {
                        Picker("Template", selection: $templateID) {
                            ForEach([PageTemplate.Source.builtIn, .user], id: \.self) { source in
                                let items = templates.filter { $0.source == source }
                                if !items.isEmpty {
                                    Section(source.rawValue) {
                                        ForEach(items) { Text($0.name).tag($0.id) }
                                    }
                                }
                            }
                        }
                        Picker("Add to", selection: $part) {
                            Text("End of book").tag(UUID?.none)
                            ForEach(project.toc.allGroups) { group in
                                Text(project.displayTitle(for: group)).tag(Optional(group.id))
                            }
                        }
                    }
                } footer: {
                    Text(footerText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    create(trimmedTitle, part, kind == .chapter ? template : nil)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedTitle.isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 440)
        .navigationTitle(kind == .chapter ? "New Chapter" : "New Part")
        .onAppear {
            part = initialPart
            templates = TemplateLibrary.pageTemplates(projectRoot: nil)
        }
    }

    private var footerText: String {
        guard !trimmedTitle.isEmpty else { return " " }
        switch kind {
        case .chapter:
            let summary = template.map { $0.summary.isEmpty ? "" : $0.summary + " " } ?? ""
            return summary + "Creates \(BookProject.path(in: project.folders.pages, BookProject.slug(for: trimmedTitle) + ".md")) and adds it to the table of contents in myst.yml."
        case .part:
            return "Adds the part to the table of contents in myst.yml."
        }
    }
}
