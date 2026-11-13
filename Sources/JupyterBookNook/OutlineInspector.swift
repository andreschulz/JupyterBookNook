import AppKit
import BookModel
import MystSyntax
import ProjectIndex
import SwiftUI

/// The headings of the current page (the one containing the cursor is highlighted) and the
/// page's problems. Clicking an entry moves the cursor there.
struct OutlineInspector: View {
    @Environment(BookStore.self) private var store
    @AppStorage("inspector.pageInfo") private var isShowingPageInfo = false

    var body: some View {
        if let document = store.currentDocument {
            let headings = document.headings
            let current = MystOutline.headingIndex(at: document.selection.location, in: headings)
            List {
                Section("Outline") {
                    if headings.isEmpty {
                        Text("Headings in this page appear here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(headings.enumerated()), id: \.offset) { index, heading in
                        row(heading, isCurrent: index == current)
                            .contentShape(Rectangle())
                            .onTapGesture { document.reveal(heading.range) }
                    }
                }
                if document.isPage {
                    if let block = DirectiveBlocks.innermost(at: document.selection.location, in: document.text) {
                        Section("Directive") {
                            DirectiveSection(block: block)
                        }
                        .id("directive-\(block.range.location)-\(block.name)")
                    }
                    Section(isExpanded: $isShowingPageInfo) {
                        PageInfoSection(document: document)
                    } header: {
                        Text("Page")
                    }
                }
                let exports = PageExports(page: document.text)
                if document.isPage, store.pageExportsEnabled || !exports.isEmpty {
                    Section("Exports") {
                        PageExportsSection(path: document.path, exports: exports)
                    }
                }
                Section(document.diagnostics.isEmpty ? "Problems" : "Problems (\(document.diagnostics.count))") {
                    if document.diagnostics.isEmpty {
                        Label("No problems found", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(document.diagnostics) { diagnostic in
                        ProblemRow(diagnostic: diagnostic)
                            .contentShape(Rectangle())
                            .onTapGesture { document.reveal(diagnostic.range) }
                    }
                }
            }
            .listStyle(.sidebar)
        } else {
            ContentUnavailableView("No page open", systemImage: "list.bullet.indent")
        }
    }

    private func row(_ heading: MystHeading, isCurrent: Bool) -> some View {
        let minLevel = store.currentDocument?.headings.map(\.level).min() ?? 1
        return VStack(alignment: .leading, spacing: 1) {
            Text(heading.title.isEmpty ? "Untitled" : heading.title)
                .fontWeight(heading.level == minLevel ? .semibold : .regular)
                .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
            if let label = heading.label {
                Text("(\(label))=")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, CGFloat(heading.level - minLevel) * 12)
        .help(heading.label.map { "Label: \($0)" } ?? "")
    }
}

struct ProblemRow: View {
    let diagnostic: Diagnostic

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: diagnostic.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(diagnostic.severity == .error ? .red : .orange)
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(diagnostic.message)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Line \(diagnostic.line)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .help(diagnostic.message)
    }
}

/// The open page's documents (format toggles) and downloads (files made elsewhere).
struct PageExportsSection: View {
    @Environment(BookStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    let path: String
    let exports: PageExports
    @State private var problem: String?

    var body: some View {
        ForEach(ProjectSettings.exportFormats, id: \.self) { format in
            Toggle(PageExports.title(of: format), isOn: Binding(
                get: { exports.formats.contains(format) },
                set: { on in
                    var changed = exports
                    changed.formats.removeAll { $0 == format }
                    if on { changed.formats.append(format) }
                    write(changed, on ? "Add \(PageExports.title(of: format))" : "Remove \(PageExports.title(of: format))")
                }
            ))
            .toggleStyle(.checkbox)
        }
        if !exports.otherExports.isEmpty {
            Text("\(exports.otherExports.count) more export\(exports.otherExports.count == 1 ? "" : "s") with own settings (in the front matter)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Text("Downloads").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
        ForEach(exports.downloads, id: \.file) { download in
            // The title is what the page's download menu shows.
            DownloadRow(download: download) { title in
                var changed = exports
                if let index = changed.downloads.firstIndex(of: download) { changed.downloads[index].title = title }
                write(changed, "Rename Download")
            } remove: {
                var changed = exports
                changed.downloads.removeAll { $0 == download }
                write(changed, "Remove Download")
            }
        }
        if !exports.otherDownloads.isEmpty {
            Text("\(exports.otherDownloads.count) more download\(exports.otherDownloads.count == 1 ? "" : "s") from the web or with own settings (in the front matter)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Button("Add File…") { addFile() }
            .buttonStyle(.link)
            .help("Offer a file from the book folder, e.g. slides made elsewhere, as a download on this page")
        if let problem {
            Text(problem).font(.caption).foregroundStyle(.orange)
        }
    }

    private func write(_ changed: PageExports, _ action: String) {
        store.setPageExports([path: changed], actionName: action, undoManager: undoManager)
    }

    private func addFile() {
        guard let project = store.project else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = project.root
        panel.canChooseDirectories = false
        panel.message = "Choose a file inside the book folder to offer for download"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let relative = project.relativePath(of: url) else {
            problem = "Choose a file inside the book folder, so the site can include it."
            return
        }
        // MyST reads download paths relative to the page.
        let page = project.url(for: path).deletingLastPathComponent()
        if exports.downloads.contains(where: { page.appendingPathComponent($0.file).standardizedFileURL == url.standardizedFileURL }) {
            problem = "\(url.lastPathComponent) is already a download of this page."
            return
        }
        problem = nil
        var changed = exports
        let stem = url.deletingPathExtension().lastPathComponent
        let type = url.pathExtension.uppercased()
        changed.downloads.append(.init(file: BookProject.reference(to: relative, from: path), title: type.isEmpty ? stem : "\(stem) (\(type))"))
        write(changed, "Add Download")
    }
}

private struct DownloadRow: View {
    let download: PageExports.Download
    let rename: (String) -> Void
    let remove: () -> Void
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if title != download.title { rename(title) } }
                RemoveButton(action: remove)
            }
            Text(download.file)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .onAppear { title = download.title }
        .onChange(of: download.title) { title = download.title }
    }
}
