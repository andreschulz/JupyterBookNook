import AppKit
import SwiftUI

/// Settings › Editor: appearance, syntax colours, font, line numbers, line width and the author of
/// new projects, with a preview next to them. The settings can be saved to a file, loaded and reset.
struct EditorSettingsView: View {
    @Bindable private var settings = EditorSettings.shared
    private let families = EditorSettings.monospacedFamilies
    @State private var isEditingColors = false
    @State private var problem: String?

    /// The spell checker's languages with readable names, sorted by name (Project Settings › Project).
    static let languages: [(id: String, name: String)] = NSSpellChecker.shared.availableLanguages.map { id in
        (id, Locale.current.localizedString(forIdentifier: id) ?? id)
    }.sorted { $0.name < $1.name }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                form
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Preview").font(.caption).foregroundStyle(.secondary)
                    SamplePreview()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                }
                .padding(16)
                .frame(width: 380)
            }
            Divider()
            HStack {
                Button("Save Settings…", action: save)
                    .help("Writes these settings, including custom syntax colours, to a file")
                Button("Load Settings…", action: load)
                    .help("Reads settings from a file saved with Save Settings…")
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button("Reset to Defaults") { settings.resetToDefaults() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .sheet(isPresented: $isEditingColors) { SyntaxColorsSheet() }
    }

    private var form: some View {
        Form {
            Section("New projects") {
                TextField("Author", text: $settings.defaultAuthor, prompt: Text("Empty: the field starts empty"))
                    .help("Filled in as the author when you create a project")
            }
            Section("Look") {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(EditorSettings.Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Syntax colours") {
                    HStack {
                        Picker("", selection: $settings.theme) {
                            ForEach(EditorSettings.Theme.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        Button("Edit Colours…") { isEditingColors = true }
                    }
                }
            }
            Section("Text") {
                Picker("Font", selection: $settings.fontName) {
                    Text("System monospaced (SF Mono)").tag("")
                    Divider()
                    ForEach(families, id: \.self) { Text($0).tag($0) }
                    if !settings.fontName.isEmpty, !families.contains(settings.fontName) {
                        Text(settings.fontName).tag(settings.fontName)
                    }
                }
                LabeledContent("Size") {
                    HStack {
                        Slider(value: $settings.fontSize, in: 10...22, step: 1)
                        Text("\(Int(settings.fontSize)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent("Line height") {
                    HStack {
                        Slider(value: $settings.lineHeight, in: 1...1.8, step: 0.05)
                        Text(String(format: "%.2f", settings.lineHeight)).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Toggle("Line numbers", isOn: $settings.showsLineNumbers)
                Toggle("Fold markers for directives and code cells", isOn: $settings.showsFoldMarkers)
                Toggle("Hide front matter (YAML at the top of a page)", isOn: $settings.hidesFrontMatter)
                    .help("Folded to its first line; click ⋯ or put the cursor in it to see it. Also View › Folding.")
                Toggle("Hide directive options (:label:, :width: …)", isOn: $settings.hidesDirectiveOptions)
                    .help("Folded into the directive's first line; the inspector still shows and edits them.")
                Toggle("Limit line width", isOn: $settings.limitsLineWidth)
                LabeledContent("Line width") {
                    HStack {
                        Slider(value: $settings.readableColumns, in: 50...120, step: 5)
                        Text("\(Int(settings.readableColumns)) characters").monospacedDigit().frame(width: 100, alignment: .trailing)
                    }
                }
                .disabled(!settings.limitsLineWidth)
            }
            Section {
                Toggle("Dim everything but the current paragraph", isOn: $settings.dimsInFocusMode)
            } header: {
                Text("Focus mode (⇧⌘↩)")
            } footer: {
                Text("Focus mode hides the sidebar, toolbar, tabs and inspector and centres the page at the line width above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "JupyterBookNook Settings.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try settings.exported().write(to: url, options: .atomic)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func load() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try settings.load(try Data(contentsOf: url))
            problem = nil
        } catch {
            problem = "\(url.lastPathComponent) is not a settings file saved by JupyterBookNook."
        }
    }
}

/// A page of MyST in the editor's font and colours, showing every syntax colour.
struct SamplePreview: NSViewRepresentable {
    /// Light or dark regardless of the app's appearance; nil follows the app.
    var dark: Bool?

    static let sample = """
    ---
    title: Gradient descent
    ---
    # Gradient descent
    The update is $x_{k+1} = x_k - \\alpha \\nabla f(x_k)$, see {numref}`fig-steps`
    and [the notes](notes.md).

    :::{figure} figs/steps.png
    :label: fig-steps
    :width: 80%

    Steps of *gradient descent*.
    :::

    :::{note}
    **Step size** matters.
    :::
    :::{tip}
    Start small.
    :::
    :::{important}
    Check convergence.
    :::
    :::{warning}
    Too large steps diverge.
    :::
    :::{danger}
    Never divide by zero.
    :::

    - A list item with `inline code`
    <!-- a comment -->

    ```python
    x = x - alpha * grad(x)
    ```
    """

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = MystTextEditor.makeTextKit1ScrollView()
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.textContainerInset = NSSize(width: 8, height: 8)
            textView.string = Self.sample
            context.coordinator.textView = textView
            context.coordinator.restyle()
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        nsView.appearance = dark.map { NSAppearance(named: $0 ? .darkAqua : .aqua) } ?? nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        weak var textView: NSTextView?
        private var observer: NSObjectProtocol?

        init() {
            observer = NotificationCenter.default.addObserver(forName: EditorSettings.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restyle() }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func restyle() {
            guard let storage = textView?.textStorage else { return }
            MystHighlighter.highlight(storage)
        }
    }
}
