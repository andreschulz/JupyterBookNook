import Foundation
import MystSyntax
import Observation
import ProjectIndex

/// A Markdown page open in a tab, or another text file (myst.yml, a plugin, CSS). PDFs, images
/// and other files that are not text open too, for viewing: the preview shows them and the
/// editor says they are not for editing.
@Observable
final class OpenDocument: Identifiable {
    let path: String
    let url: URL
    /// A file to look at, not to edit (PDF, PNG, …): it has no text and is never saved.
    let isViewOnly: Bool
    /// Files that are opened for viewing without trying to read them as text. SVG is text and
    /// opens in the editor.
    static let viewOnlyExtensions: Set<String> = [
        "pdf", "png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "bmp", "heic", "ico",
        "mp4", "mov", "m4v", "mp3", "wav", "zip", "docx", "xlsx", "pptx", "eps",
    ]
    var text: String
    private(set) var savedText: String

    /// Called after each edit in the editor (not for reloads from disk).
    @ObservationIgnored var onEdit: (() -> Void)?

    /// The current selection in the editor (UTF-16 based).
    var selection = NSRange(location: 0, length: 0)
    /// Headings of the page, kept up to date by the editor.
    var headings: [MystHeading] = []
    /// Problems in the page found while editing (unknown labels, missing files, …).
    var diagnostics: [Diagnostic] = []
    /// A request for the editor to show and select a range (from the outline).
    var revealRequest: RevealRequest?
    /// The tab shows the page like the book (View › Book View) instead of its MyST source.
    /// New tabs start the way the last one was switched.
    var isBookView = UserDefaults.standard.bool(forKey: "editor.bookView") {
        didSet { UserDefaults.standard.set(isBookView, forKey: "editor.bookView") }
    }
    /// Only Markdown pages have a book view.
    var isPage: Bool { path.lowercased().hasSuffix(".md") }

    /// What the preview shows for this tab.
    enum PreviewKind { case site, file, none }

    /// Pages show the book's site; images, PDFs and SVG drawings show the file itself; other text
    /// files (myst.yml, plugins, CSS, BibTeX…) have no preview.
    var previewKind: PreviewKind {
        if isViewOnly { return .file }
        switch url.pathExtension.lowercased() {
        case "md", "ipynb": return .site
        case "svg": return .file
        default: return .none
        }
    }

    struct RevealRequest: Equatable {
        let id = UUID()
        let range: NSRange
    }

    var id: String { path }
    var isDirty: Bool { text != savedText }
    var fileName: String { url.lastPathComponent }

    init(path: String, root: URL) throws {
        self.path = path
        url = root.appendingPathComponent(path)
        // @Observable turns `text` into a computed property, so it cannot be read
        // until every stored property is set; go through a local instead.
        var contents = ""
        var viewOnly = Self.viewOnlyExtensions.contains(url.pathExtension.lowercased())
        if !viewOnly {
            let data = try Data(contentsOf: url)
            // A file that is not UTF-8 text is shown, not edited.
            if let text = String(data: data, encoding: .utf8) { contents = text } else { viewOnly = true }
        } else if !FileManager.default.fileExists(atPath: url.path) {
            throw CocoaError(.fileNoSuchFile)
        }
        isViewOnly = viewOnly
        text = contents
        savedText = contents
        headings = MystOutline.headings(in: contents)
    }

    func reveal(_ range: NSRange) {
        revealRequest = RevealRequest(range: range)
    }

    /// The range of a 1-based line, for jumping to a build message.
    func rangeOfLine(_ line: Int) -> NSRange {
        let ns = text as NSString
        var start = 0
        var current = 1
        while current < line, start < ns.length {
            let range = ns.lineRange(for: NSRange(location: start, length: 0))
            start = NSMaxRange(range)
            current += 1
        }
        guard start < ns.length else { return NSRange(location: ns.length, length: 0) }
        var end = 0
        var contentsEnd = 0
        ns.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
        return NSRange(location: start, length: contentsEnd - start)
    }

    /// 1-based line and column of the cursor.
    var cursorPosition: (line: Int, column: Int) {
        // Read on every keystroke (breadcrumb bar): one pass over the UTF-16 units before the cursor.
        var line = 1
        var lineStart = 0
        var index = 0
        for unit in text.utf16.prefix(selection.location) {
            index += 1
            if unit == 10 {
                line += 1
                lineStart = index
            }
        }
        return (line, index - lineStart + 1)
    }

    func save() throws {
        guard !isViewOnly else { return }
        try text.write(to: url, atomically: true, encoding: .utf8)
        savedText = text
        diskConflict = nil
    }

    /// The file changed or disappeared on disk while the tab had unsaved edits. The tab is not
    /// saved over it until the user decides (banner above the editor).
    var diskConflict: DiskConflict?

    enum DiskConflict { case changed, deleted }

    /// Compares the tab with its file after a change on disk: a tab without edits follows the
    /// file; one with edits is marked as conflicting.
    func diskDidChange() {
        if isViewOnly {
            // The preview shows the file again.
            diskRevision += 1
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            if isDirty || diskConflict != nil { diskConflict = .deleted }
            return
        }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        if contents == savedText {
            if diskConflict == .deleted { diskConflict = nil }
            return
        }
        if contents == text {
            // Saved elsewhere with the same text.
            savedText = contents
            diskConflict = nil
        } else if isDirty {
            diskConflict = .changed
        } else {
            reloadFromDisk()
        }
    }

    /// Replaces the text while no editor shows it (it reads the text when it appears).
    func useText(_ newText: String) {
        guard newText != text else { return }
        diskRevision += 1
        text = newText
        headings = MystOutline.headings(in: newText)
    }

    /// Drops the edits in the tab and shows the file as it is on disk.
    func useDiskVersion() {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        diskRevision += 1
        text = contents
        savedText = contents
        headings = MystOutline.headings(in: contents)
        diskConflict = nil
    }

    /// Counts reloads from disk; the editor replaces its text only when this changes (for
    /// view-only files, the preview shows the file again).
    private(set) var diskRevision = 0

    /// Picks up a change made on disk by a structural operation (for example a rewritten link).
    /// Only called when the document has no unsaved edits.
    func reloadFromDisk() {
        guard let contents = try? String(contentsOf: url, encoding: .utf8), contents != savedText else { return }
        diskRevision += 1
        text = contents
        savedText = contents
        headings = MystOutline.headings(in: contents)
    }
}
