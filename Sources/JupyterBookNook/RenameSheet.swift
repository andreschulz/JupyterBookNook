import BookModel
import SwiftUI

/// Renames a page (its title and/or file) or a part. Changing the file name also updates
/// myst.yml and every link to the page, as one undoable step.
struct RenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: RenameRequest
    let project: BookProject
    let renamePage: (_ path: String, _ title: String, _ newPath: String) -> Void
    let renamePart: (_ id: UUID, _ title: String) -> Void

    @State private var title = ""
    @State private var path = ""
    @State private var fileNameFollowsTitle = false

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var originalPath: String? {
        if case .page(let path) = request { return path }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Title", text: $title)
                        .onChange(of: title) { _, newTitle in
                            if fileNameFollowsTitle { path = suggestedPath(for: newTitle) }
                        }
                    if originalPath != nil {
                        TextField("File", text: $path)
                            .onChange(of: path) { _, newPath in
                                fileNameFollowsTitle = newPath == suggestedPath(for: title)
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
                Button("Rename") {
                    switch request {
                    case .page(let original):
                        renamePage(original, trimmedTitle, path.trimmingCharacters(in: .whitespaces))
                    case .part(let id):
                        renamePart(id, trimmedTitle)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedTitle.isEmpty || (originalPath != nil && path.trimmingCharacters(in: .whitespaces).isEmpty))
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
        .onAppear(perform: load)
    }

    private func load() {
        switch request {
        case .page(let original):
            title = project.pageTitles[original] ?? URL(fileURLWithPath: original).deletingPathExtension().lastPathComponent
            path = original
        case .part(let id):
            title = project.toc.entry(id: id).map(project.displayTitle(for:)) ?? ""
        }
    }

    /// The file name a title would get, in the page's current folder.
    private func suggestedPath(for title: String) -> String {
        guard let originalPath else { return path }
        let folder = (originalPath as NSString).deletingLastPathComponent
        let name = BookProject.slug(for: title) + ".md"
        return folder.isEmpty ? name : folder + "/" + name
    }

    private var footerText: String {
        guard let originalPath else { return "Updates the part's title in myst.yml." }
        let newPath = path.trimmingCharacters(in: .whitespaces)
        if newPath == originalPath {
            return "Changes the title in the page. To rename the file too, edit the file name; it can include a folder, such as chapters/\(BookProject.slug(for: trimmedTitle)).md."
        }
        return "Moves \(originalPath) to \(newPath) and updates myst.yml and the links in other pages."
    }
}
