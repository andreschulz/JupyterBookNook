import AppKit
import BookModel
import BuildService
import SwiftUI
import UniformTypeIdentifiers

/// Plugins (sidebar › Project › Plugins): the book's `project.plugins`, with the directives and
/// roles each adds. Adding, removing and switching plugins on and off updates myst.yml.
struct PluginsView: View {
    @Environment(BookStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    let project: BookProject

    @State private var isAddingURL = false

    var body: some View {
        let plugins = store.allPlugins
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Plugins").font(.system(size: 26, weight: .bold))
                    Text("Plugins add directives, roles and transforms to MyST. They are listed under project.plugins in myst.yml.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if plugins.isEmpty {
                ContentUnavailableView {
                    Label("No plugins", systemImage: "puzzlepiece.extension")
                } description: {
                    Text("A plugin is a JavaScript file in the book or at a URL. Start with a small one that adds a directive and a role, or add one you have.")
                } actions: {
                    HStack {
                        Button("New Plugin…") { store.isShowingNewPlugin = true }
                        Button("Add File…") { chooseFile() }
                        Button("Add from URL…") { isAddingURL = true }
                        Menu("From Your Library") { libraryItems }
                            .fixedSize()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(plugins, id: \.entry.id) { plugin in
                            PluginCard(entry: plugin.entry, isEnabled: plugin.isEnabled, status: store.pluginStatus[plugin.entry.source])
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
            Divider()
            HStack {
                Menu("Add Plugin") {
                    Button("New Plugin…") { store.isShowingNewPlugin = true }
                    Button("Add File…") { chooseFile() }
                    Button("Add from URL…") { isAddingURL = true }
                    Divider()
                    Menu("From Your Plugin Library") { libraryItems }
                } primaryAction: {
                    chooseFile()
                }
                .fixedSize()
                Button("Read Again") { store.inspectPlugins(reload: true) }
                    .help("Read what each plugin adds again; plugins from URLs are downloaded again")
                    .disabled(plugins.isEmpty)
                Spacer()
                Label("Plugins run code on this Mac during every build. Only add plugins you trust.", systemImage: "exclamationmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .onAppear { store.reloadPluginLibrary() }
        .sheet(isPresented: $isAddingURL) { AddPluginURLSheet { store.addPluginURL($0, undoManager: undoManager) } }
        .sheet(isPresented: Binding(get: { store.isShowingNewPlugin }, set: { store.isShowingNewPlugin = $0 })) { NewPluginSheet() }
    }

    /// The library's plugins; ones the book already has are shown but cannot be added again.
    @ViewBuilder
    private var libraryItems: some View {
        if store.pluginLibrary.isEmpty {
            Text("Your plugin library is empty")
        }
        ForEach(store.pluginLibrary) { plugin in
            let has = store.bookHasLibraryPlugin(plugin)
            Button(has ? "\(plugin.name) (in this book)" : plugin.name) { store.addLibraryPlugin(plugin, undoManager: undoManager) }
                .disabled(has)
        }
        Divider()
        Button("Manage Plugin Library…") { store.showAppSettings(.plugins) }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.message = "Choose a MyST plugin (.mjs or .js). A file from outside the book is copied into its plugins folder."
        panel.allowedContentTypes = ["mjs", "js", "cjs"].compactMap { UTType(filenameExtension: $0) }
        panel.directoryURL = project.root
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.addPluginFile(url, undoManager: undoManager)
    }
}

/// One plugin: name, source, what it adds, and a switch.
struct PluginCard: View {
    @Environment(BookStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    let entry: PluginEntry
    let isEnabled: Bool
    let status: PluginStatus?

    private var spec: PluginSpec? {
        if case .read(let spec)? = status { return spec }
        return nil
    }

    private var icon: String {
        entry.isExecutable ? "terminal" : entry.isURL ? "globe" : "doc.text"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(isEnabled ? Color.accentColor : .secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec?.name ?? entry.fileName)
                        .font(.headline)
                    Text(entry.source)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Toggle("On", isOn: Binding(get: { isEnabled }, set: { store.setPlugin(entry, enabled: $0, undoManager: undoManager) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(isEnabled ? "Switch off: taken out of myst.yml, kept here" : "Switch on: listed in myst.yml again")
                Menu {
                    Button(entry.isURL ? "Open in Browser" : "Open in Editor") { store.openPlugin(entry) }
                    if !entry.isURL, let project = store.project {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([project.url(for: BookProject.normalized(entry.source))])
                        }
                    }
                    if !entry.isExecutable {
                        Button(store.isInLibrary(entry) ? "In Your Plugin Library" : "Add to Your Plugin Library") { store.addToLibrary(entry) }
                            .disabled(store.isInLibrary(entry))
                    }
                    Divider()
                    Button("Remove from Book", role: .destructive) { store.removePlugin(entry, undoManager: undoManager) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            PluginDetails(status: status, isExecutable: entry.isExecutable,
                          failureNote: isEnabled ? " Unknown directives and roles are not reported while it cannot be read." : "")
                .padding(.leading, 38)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
        .opacity(isEnabled ? 1 : 0.65)
    }
}

/// What a plugin adds, as name chips, or why that is not known.
struct PluginDetails: View {
    let status: PluginStatus?
    let isExecutable: Bool
    /// Added to a failure message, e.g. what that means for the book.
    var failureNote = ""

    var body: some View {
        switch status ?? (isExecutable ? .executable : nil) {
        case nil, .reading?:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading what it adds…").font(.caption).foregroundStyle(.secondary)
            }
        case .executable?:
            Text("An executable plugin: MyST runs it while building. What it adds is not known here, so unknown directives and roles are not reported.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message)?:
            Label {
                Text(message + failureNote)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.caption)
        case .read(let spec)?:
            VStack(alignment: .leading, spacing: 6) {
                if !spec.directives.isEmpty { names("Directives", spec.directives, role: false) }
                if !spec.roles.isEmpty { names("Roles", spec.roles, role: true) }
                if !spec.transforms.isEmpty {
                    Text("Transforms: " + spec.transforms.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func names(_ title: String, _ items: [PluginSpec.Item], role: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            FlowLayout(spacing: 6) {
                ForEach(items, id: \.name) { item in
                    Text("{\(item.name)}" + (role ? "`…`" : ""))
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                        .help(help(for: item))
                }
            }
        }
    }

    private func help(for item: PluginSpec.Item) -> String {
        var lines: [String] = []
        if let doc = item.doc { lines.append(doc) }
        if !item.aliases.isEmpty { lines.append("Also: " + item.aliases.joined(separator: ", ")) }
        if !item.options.isEmpty { lines.append("Options: " + item.options.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }
}

/// Adds a plugin by URL, after saying what that means: MyST downloads and runs it in every build.
struct AddPluginURLSheet: View {
    @Environment(\.dismiss) private var dismiss
    let add: (String) -> Void
    @State private var address = ""
    @State private var understood = false

    private var isValid: Bool {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "https" || scheme == "http") && url.host != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Plugin from a URL").font(.headline)
            TextField("https://…/plugin.mjs", text: $address)
                .textFieldStyle(.roundedBorder)
                .frame(width: 420)
            Label {
                Text("MyST downloads this file and runs it on your Mac in every build and preview. It can do anything a program you run can do, and its author can change it later. Add only plugins from sources you trust.")
            } icon: {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
            }
            .font(.callout)
            .frame(width: 420, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            Toggle("I trust this source", isOn: $understood)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Plugin") {
                    add(address.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || !understood)
            }
        }
        .padding(20)
    }
}

/// Creates a starter plugin with one directive and one role, named after the plugin.
struct NewPluginSheet: View {
    @Environment(BookStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var slug: String {
        let words = name.lowercased().split { !$0.isLetter && !$0.isNumber }
        return words.isEmpty ? "my-plugin" : words.joined(separator: "-")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Plugin").font(.headline)
            TextField("Name, e.g. Boxes", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 380)
                .onSubmit(create)
            Text("Creates \(BookProject.path(in: store.project?.folders.plugins ?? BookFolders.defaults.plugins, slug + ".mjs")) with a {\(slug)} directive and a {\(slug)} role to start from, adds it to myst.yml and opens it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 380, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func create() {
        let title = name.trimmingCharacters(in: .whitespaces)
        store.createPlugin(named: title.isEmpty ? "My Plugin" : title, undoManager: undoManager)
        dismiss()
    }
}
