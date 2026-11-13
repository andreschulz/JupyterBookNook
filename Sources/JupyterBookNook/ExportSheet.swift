import AppKit
import BookModel
import BuildService
import SwiftUI

/// Export HTML site (mockup 05): options, then the build with its progress and log.
struct ExportSheet: View {
    @Environment(BookStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager
    let project: BookProject

    @State private var destination: URL?
    @State private var baseURL = ""
    @State private var theme = ""
    @State private var strict = false
    @State private var reveal = true
    @State private var zip = false
    /// Set once Export was pressed, so the progress shows this build.
    @State private var started = false

    private var defaultFolder: URL { project.root.appendingPathComponent("_build/html", isDirectory: true) }
    private var folder: URL { destination ?? defaultFolder }
    private var build: BuildController { store.build }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Export HTML site").font(.title2.weight(.semibold))
                Text("Runs ").foregroundStyle(.secondary)
                    + Text("myst build --html").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                    + Text(" — the result is exactly what visitors see in their browser.").foregroundStyle(.secondary)
            }
            LabeledField("Output folder") {
                HStack {
                    Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
                    Button("Choose…") { chooseFolder() }
                    if destination != nil {
                        Button("Default") { destination = nil }
                    }
                }
            }
            HStack(alignment: .top, spacing: 14) {
                LabeledField("Base URL", help: "The path the site is served under, e.g. /\(BookSlug.fileName(for: project.title))/ for GitHub Pages. Empty for a site at the root of a domain.") {
                    TextField("", text: $baseURL, prompt: Text("/"))
                }
                LabeledField("Theme") {
                    Picker("", selection: $theme) {
                        Text("book-theme").tag("")
                        ForEach(ProjectSettings.templates.filter { $0 != "book-theme" }, id: \.self) { Text($0).tag($0) }
                        if !theme.isEmpty, !ProjectSettings.templates.contains(theme) { Text(theme).tag(theme) }
                    }
                    .labelsHidden()
                }
            }
            VStack(spacing: 0) {
                Divider()
                toggleRow("Strict mode", detail: "Treat warnings (e.g. unresolved references) as errors", isOn: $strict)
                Divider()
                toggleRow("Show in Finder when done", detail: nil, isOn: $reveal)
                Divider()
                toggleRow("Also create a .zip for upload", detail: zip ? "Saved next to the output folder" : nil, isOn: $zip)
            }
            if started { progress }
            HStack {
                Button("Reveal in Finder") {
                    let target = FileManager.default.fileExists(atPath: folder.path) ? folder : project.root
                    NSWorkspace.shared.activateFileViewerSelecting([target])
                }
                Spacer()
                Button(build.isBuilding && started ? "Stop" : "Close", role: .cancel) {
                    if build.isBuilding && started { build.cancelBuild() } else { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
                Button("Export") { export() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(build.isBuilding)
            }
        }
        .padding(28)
        .frame(width: 620)
        .onAppear {
            let settings = ProjectSettings(yaml: project.configText)
            theme = settings.template == "book-theme" ? "" : settings.template
            baseURL = UserDefaults.standard.string(forKey: baseURLKey) ?? ""
            if let path = UserDefaults.standard.string(forKey: folderKey) { destination = URL(fileURLWithPath: path, isDirectory: true) }
        }
    }

    private var baseURLKey: String { "export.baseURL." + project.root.standardizedFileURL.path }
    private var folderKey: String { "export.folder." + project.root.standardizedFileURL.path }

    private func toggleRow(_ title: String, detail: String?, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .padding(.vertical, 8)
    }

    // MARK: Progress

    private var totalPages: Int { max(project.toc.allFiles.count, 1) }

    @ViewBuilder
    private var progress: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(statusText).fontWeight(.medium)
                Spacer()
                if case .running(let start) = build.buildState {
                    TimelineView(.periodic(from: .now, by: 0.1)) { context in
                        Text(String(format: "%.1f s", context.date.timeIntervalSince(start)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                } else if case .finished(_, let duration) = build.buildState {
                    Text(String(format: "%.1f s", duration)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            ProgressView(value: fraction)
                .tint(isFailed ? .red : .accentColor)
            logView
        }
    }

    private var fraction: Double {
        switch build.buildState {
        case .running: return min(Double(build.builtPages) / Double(totalPages), 0.95)
        case .finished(let ok, _): return ok ? 1 : Double(build.builtPages) / Double(totalPages)
        default: return 0
        }
    }

    private var isFailed: Bool {
        switch build.buildState {
        case .failed: return true
        case .finished(let ok, _): return !ok
        default: return false
        }
    }

    private var statusText: String {
        switch build.buildState {
        case .running: return "Building… \(min(build.builtPages, totalPages)) of \(totalPages) pages"
        case .finished(true, _):
            let warnings = build.buildMessages.count
            return warnings == 0 ? "Exported" : "Exported with \(warnings) warning\(warnings == 1 ? "" : "s")"
        case .finished(false, _): return strict ? "Stopped: strict mode found problems" : "The build failed"
        case .failed(let message): return message
        case .idle: return ""
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    Text("$ myst build --html" + (strict ? " --strict" : "")).foregroundStyle(.gray)
                    // Problems are listed after the log, with a link to the page.
                    // MyST's request log while it writes the static site ("GET /intro.json 200") is left out.
                    let lines = build.buildLog.suffix(200).filter { line in
                        !line.hasPrefix("⚠") && !line.hasPrefix("⛔") && !line.contains("GET /")
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        logLine(line)
                    }
                    ForEach(build.buildMessages) { message in
                        HStack(spacing: 8) {
                            Text(message.severity == .error ? "⛔" : "⚠").foregroundStyle(.yellow)
                            Text([message.file, message.line.map(String.init)].compactMap { $0 }.joined(separator: ":") + "  " + message.text)
                                .lineLimit(2)
                            if let file = message.file, let project = store.project, project.fileExists(file) || project.fileExists(file + ".md") {
                                Button("Show") {
                                    dismiss()
                                    store.settingsTab = nil
                                    store.showMessage(message)
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Color(white: 0.92))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .frame(height: 190)
            .background(Color(red: 0.11, green: 0.12, blue: 0.15), in: RoundedRectangle(cornerRadius: 9))
            .onChange(of: build.buildLog.count) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: build.buildMessages.count) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private func logLine(_ line: String) -> some View {
        let clean = line.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        let built = clean.contains("Built ")
        return Text((built ? "✓ " : "  ") + clean.trimmingCharacters(in: .whitespaces))
            .foregroundStyle(built ? Color(white: 0.92) : .gray)
            .lineLimit(1)
    }

    // MARK: Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder.deletingLastPathComponent()
        panel.prompt = "Choose"
        panel.message = "The site’s files are copied into this folder; files with the same names are replaced."
        if panel.runModal() == .OK, let url = panel.url { destination = url }
    }

    private func export() {
        UserDefaults.standard.set(baseURL, forKey: baseURLKey)
        if let destination {
            UserDefaults.standard.set(destination.path, forKey: folderKey)
        } else {
            UserDefaults.standard.removeObject(forKey: folderKey)
        }
        // The theme is a setting of the book, so it is written to myst.yml (one undo step).
        let old = ProjectSettings(yaml: project.configText)
        var new = old
        new.template = theme.isEmpty ? (old.template.isEmpty ? "" : "book-theme") : theme
        if new.template != old.template {
            guard store.applySettings(new, from: old, undoManager: undoManager) else { return }
        }
        started = true
        let options = BuildOptions(execute: build.executesNotebooks(project.root), strict: strict, baseURL: baseURL)
        store.exportSite(options: options, destination: folder, zip: zip, reveal: reveal)
    }
}
