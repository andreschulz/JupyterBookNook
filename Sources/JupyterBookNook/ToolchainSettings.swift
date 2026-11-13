import BuildService
import SwiftUI

/// Settings › MyST: which MyST installation builds and previews books, globally and per book.
struct ToolchainSettings: View {
    @Environment(BookStore.self) private var store
    @State private var customCommand = ""

    var body: some View {
        let build = store.build
        Form {
            Section {
                choicePicker("Default", selection: Binding(get: { build.defaultChoice }, set: { build.defaultChoice = $0 }))
                HStack {
                    TextField("Custom command", text: $customCommand, prompt: Text("e.g. npx mystmd"))
                    Button("Use as Default") { build.defaultChoice = .custom(customCommand) }
                        .disabled(customCommand.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("MyST installation")
            } footer: {
                Text("MyST builds the book and runs the preview. The editor works without it. "
                     + "Automatic uses the book’s own .venv or node_modules first, then the installation below, then one on your PATH. "
                     + "A book can use another installation: Project Settings › Execution.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Installed by JupyterBookNook") {
                managedRow
            }

            Section {
                if build.candidates.isEmpty {
                    Text(build.isDetecting ? "Searching…" : "No myst or jupyter-book found.")
                        .foregroundStyle(.secondary)
                }
                ForEach(build.candidates, id: \.self) { toolchain in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(toolchain.displayName)
                            Text(toolchain.command)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Text(build.versions[toolchain] ?? "…")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } header: {
                HStack {
                    Text("Found on this Mac")
                    Spacer()
                    Button("Search Again") { Task { await build.detectToolchains() } }
                        .disabled(build.isDetecting)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if case .custom(let command) = build.defaultChoice { customCommand = command }
        }
    }

    @ViewBuilder
    private var managedRow: some View {
        let build = store.build
        switch build.managedState {
        case .installing(let step, let fraction):
            VStack(alignment: .leading, spacing: 6) {
                Text(step)
                if let fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Label("Installation failed", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                Text(reason).font(.caption.monospaced()).textSelection(.enabled)
                Button("Try Again") { build.installManaged() }
            }
        case .idle:
            if build.isManagedInstalled {
                HStack {
                    let versions = build.managed.installedVersions
                    Text("MyST \(versions?.myst ?? "?") with Node.js \(versions?.node ?? "?")")
                    Spacer()
                    Button("Remove") { build.removeManaged() }
                }
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MyST \(ManagedToolchain.mystVersion) with its own Node.js \(ManagedToolchain.nodeVersion)")
                        Text("About 100 MB in Application Support. Nothing is installed system-wide.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Install") { build.installManaged() }
                }
            }
        }
    }

    private func choicePicker(_ title: String, selection: Binding<ToolchainChoice>) -> some View {
        Picker(title, selection: selection) {
            ForEach(store.build.choiceOptions(for: store.project?.root), id: \.self) { option in
                Text(store.build.label(for: option, root: store.project?.root)).tag(option)
            }
        }
    }
}

/// Project Settings › Execution: which MyST installation builds this book (an app setting per book).
struct BookToolchainPicker: View {
    @Environment(BookStore.self) private var store
    let root: URL

    var body: some View {
        let build = store.build
        Picker("MyST installation", selection: Binding(get: { build.choice(for: root) }, set: { build.setChoice($0, for: root) })) {
            Text("Same as for all books — \(build.label(for: build.defaultChoice, root: root))").tag(ToolchainChoice?.none)
            Divider()
            ForEach(build.choiceOptions(for: root), id: \.self) { option in
                Text(build.label(for: option, root: root)).tag(Optional(option))
            }
        }
    }
}

extension BuildController {
    /// The installations to choose from: automatic, the managed one, those found on this Mac and
    /// any that is chosen already.
    func choiceOptions(for root: URL?) -> [ToolchainChoice] {
        var options: [ToolchainChoice] = [.automatic]
        if isManagedInstalled { options.append(.managed) }
        options += candidates.filter { $0.source != .managed && $0.source != .custom }.map { .executable($0.command) }
        for choice in [defaultChoice] + (root.flatMap { choice(for: $0) }.map { [$0] } ?? []) where !options.contains(choice) {
            options.append(choice)
        }
        return options
    }

    func label(for choice: ToolchainChoice, root: URL?) -> String {
        switch choice {
        case .automatic:
            let resolved = locator.resolve(.automatic, for: root)
            return "Automatic" + (resolved.map { " (\($0.displayName))" } ?? " (none found)")
        case .managed: return "Installed by JupyterBookNook"
        case .executable(let path): return candidates.first { $0.command == path }?.displayName ?? path
        case .custom(let command): return "Custom: \(command)"
        }
    }
}

/// Shown when Build or Preview is used and no MyST installation is available.
struct ToolchainSetupSheet: View {
    @Environment(BookStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Set up MyST").font(.title2.weight(.semibold))
                Text("Building and previewing a book needs MyST (mystmd). Install a private copy, or choose one that is already on this Mac.")
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 20)
            ToolchainSettings()
                .frame(minHeight: 360)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 560)
    }
}
