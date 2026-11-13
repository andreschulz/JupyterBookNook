import AppKit
import BookModel
import Foundation

/// The book's style (sidebar › Project › Style), written to its stylesheet.
extension BookStore {
    /// Writes the style as one undoable step; the preview picks the file up by itself.
    func saveStyle(_ style: BookStyle, actionName: String = "Change Style", undoManager: UndoManager?) {
        perform(actionName, undoManager, showsNotice: false) { try $0.setStyle(style) }
    }

    /// A myst.yml setting from the style editor (site name, footer, hiding parts of the site).
    func setConfigValue(_ path: [String], to value: YAMLValue?, summary: String, undoManager: UndoManager?) {
        perform("Change Site Setting", undoManager, showsNotice: false) { try $0.setConfigValue(path, to: value, summary: summary) }
        build.reloadPreviewSoon()
    }

    func useStylesheet(_ path: String, undoManager: UndoManager?) {
        perform("Use Stylesheet", undoManager) { try $0.useStylesheet(path) }
    }

    /// Saves the style to the library for all books.
    func saveStyleToLibrary(_ style: BookStyle, named name: String) {
        do {
            try StyleLibrary.save(style, named: name)
            notice = Notice(message: "Saved the style “\(name)” to your styles", change: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The style of another book, chosen in an open panel (its folder or its myst.yml).
    func chooseStyleFromAnotherBook() -> BookStyle? {
        let panel = NSOpenPanel()
        panel.message = "Choose another book's folder: its style (site.options.style) is loaded into this book."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = project?.root.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let other = try BookProject(root: url)
            guard let path = other.stylesheet else {
                errorMessage = "“\(other.title)” has no stylesheet (site.options.style)."
                return nil
            }
            var style = BookStyle(css: try String(contentsOf: other.url(for: path), encoding: .utf8))
            if style.name.isEmpty { style.name = other.title }
            return style
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
