import SwiftUI

/// The Settings window (⌘,): how the app works for every book — the editor, templates, the
/// plugin library and the MyST installation. What belongs to one book is in Project Settings (⌥⌘,).
struct AppSettingsView: View {
    @Environment(BookStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            TabView(selection: $store.appSettingsTab) {
                EditorSettingsView()
                    .tabItem { Label("Editor", systemImage: "textformat") }
                    .tag(AppSettingsTab.editor)
                TemplateEditorView()
                    .tabItem { Label("Templates", systemImage: "square.grid.2x2") }
                    .tag(AppSettingsTab.templates)
                PluginLibraryView()
                    .tabItem { Label("Plugins", systemImage: "puzzlepiece.extension") }
                    .tag(AppSettingsTab.plugins)
                ToolchainSettings()
                    .tabItem { Label("MyST", systemImage: "shippingbox") }
                    .tag(AppSettingsTab.myst)
            }
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("These settings apply to all books.")
                    .foregroundStyle(.secondary)
                if store.project != nil {
                    Button("Project Settings of “\(store.project?.title ?? "")”…") { store.showSettings() }
                        .buttonStyle(.link)
                }
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: size.width, height: size.height)
        .animation(.snappy, value: store.appSettingsTab)
    }

    /// Templates need room for the list and the editor; the forms are narrower.
    private var size: CGSize {
        switch store.appSettingsTab {
        case .editor: return CGSize(width: 980, height: 720)
        case .templates: return CGSize(width: 900, height: 640)
        case .plugins: return CGSize(width: 680, height: 560)
        case .myst: return CGSize(width: 600, height: 520)
        }
    }
}
