import SwiftUI

/// A short tour of what the app does, shown once when the first book opens and from
/// Help › Welcome Tour. One page per idea, with the shortcut to remember.
struct WelcomeTour: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    struct Page {
        let symbol: String
        let title: String
        let text: String
        let keys: [(String, String)]
    }

    static let pages: [Page] = [
        Page(symbol: "books.vertical", title: "Your book, organised",
             text: "The sidebar is the table of contents. Add chapters and parts, drag pages to reorder them, rename or remove them — myst.yml is updated for you, and every change can be undone.",
             keys: [("⇧⌘N", "New chapter"), ("⌘Z", "Undo any change to the book")]),
        Page(symbol: "text.cursor", title: "Write MyST with help",
             text: "Directives, roles, labels, citations and paths complete as you type. Snippets insert figures, tables and admonitions; ⇥ jumps between their fields. Problems are underlined and listed in the inspector.",
             keys: [("⌘T", "Insert a snippet"), ("Esc", "Show completions"), ("⌘V", "Paste a screenshot as a figure")]),
        Page(symbol: "rectangle.split.2x1", title: "See the book while you write",
             text: "Split view shows the live preview next to the editor and keeps both on the same section. Build, export a site or documents from the toolbar.",
             keys: [("⌘1 ⌘2 ⌘3", "Editor, split, preview"), ("⌘B", "Build"), ("⇧⌘E", "Export HTML")]),
        Page(symbol: "magnifyingglass", title: "Find anything",
             text: "Quick Open finds pages, labels and files by a few letters. The command palette runs any command. Focus mode hides everything but the page.",
             keys: [("⌘P", "Quick Open"), ("⇧⌘P", "Command palette"), ("⇧⌘↩", "Focus mode")]),
        Page(symbol: "gearshape.2", title: "Two kinds of settings",
             text: "Project Settings belong to one book and edit its myst.yml with forms, keeping your comments. Settings (⌘,) are the same for every book: fonts, colours, line numbers, your snippets and page templates, and the MyST installation.",
             keys: [("⌥⌘,", "Project settings"), ("⌥⌘0", "Inspector"), ("⌘,", "App settings")]),
    ]

    var body: some View {
        let current = Self.pages[page]
        VStack(spacing: 18) {
            Image(systemName: current.symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
                .frame(height: 56)
            Text(current.title).font(.title2.weight(.semibold))
            Text(current.text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(current.keys, id: \.0) { key, meaning in
                    GridRow {
                        Text(key)
                            .font(.system(.callout, design: .rounded).weight(.medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
                            .gridColumnAlignment(.trailing)
                        Text(meaning).font(.callout)
                    }
                }
            }
            .frame(minHeight: 80, alignment: .top)
            HStack(spacing: 6) {
                ForEach(Self.pages.indices, id: \.self) { index in
                    Circle()
                        .fill(index == page ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                        .onTapGesture { page = index }
                }
            }
            HStack {
                Button("Skip") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if page > 0 {
                    Button("Back") { page -= 1 }
                }
                Button(page == Self.pages.count - 1 ? "Start Writing" : "Next") {
                    if page == Self.pages.count - 1 { dismiss() } else { page += 1 }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(width: 520)
    }
}
