import AppKit
import MystSyntax

/// What the table assistant edits: a table of the current page, or a new one at the cursor.
struct TableAssistantRequest: Identifiable {
    let id = UUID()
    let path: String
    /// The table's source in the page; for a new table, where it goes.
    let range: NSRange
    /// The source as it was, to tell whether the page changed meanwhile.
    let original: String
    let table: MystTable
    let isNew: Bool
    /// The 1-based line the table starts on.
    let line: Int
}

extension BookStore {
    /// Opens the table assistant for the table at `location` in the editor (the cursor when nil);
    /// without a table there, for a new table at the cursor.
    func showTableAssistant(at location: Int? = nil) {
        guard let textView = editorTextView, let document = currentDocument, document.isPage, settingsTab == nil else { return }
        let text = textView.string as NSString
        let cursor = textView.selectedRange().location
        func line(_ location: Int) -> Int {
            text.substring(to: min(location, text.length)).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        }
        if let block = MystTables.table(at: location ?? cursor, in: textView.string) {
            tableAssistant = TableAssistantRequest(path: document.path, range: block.range, original: text.substring(with: block.range),
                                                   table: block.table, isNew: false, line: line(block.range.location))
        } else {
            tableAssistant = TableAssistantRequest(path: document.path, range: NSRange(location: cursor, length: 0), original: "",
                                                   table: .empty(), isNew: true, line: line(cursor))
        }
    }

    /// Writes the assistant's table into the page, as one undo step.
    func applyTable(_ table: MystTable, for request: TableAssistantRequest) {
        tableAssistant = nil
        guard currentPath == request.path, let textView = editorTextView as? MystTextView else {
            errorMessage = "The page of the table is no longer open in the editor; nothing was changed."
            return
        }
        let text = textView.string as NSString
        if request.isNew {
            // A table needs blank lines around it.
            let location = min(request.range.location, text.length)
            let lineStart = text.lineRange(for: NSRange(location: location, length: 0)).location
            let before = text.substring(with: NSRange(location: lineStart, length: location - lineStart))
            let previousBlank = lineStart == 0 || text.lineRange(for: NSRange(location: lineStart - 1, length: 0)).length <= 1
            var body = table.markdown + "\n"
            if !before.trimmingCharacters(in: .whitespaces).isEmpty || !previousBlank { body = "\n" + body }
            let lineEnd = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0)))
            if lineEnd < text.length || !text.substring(with: NSRange(location: location, length: lineEnd - location)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                body += "\n"
            }
            textView.insert(body, selecting: NSRange(location: (body as NSString).length, length: 0),
                            replacing: NSRange(location: location, length: 0), actionName: "Insert Table")
            return
        }
        var range = request.range
        if NSMaxRange(range) > text.length || text.substring(with: range) != request.original {
            // The page changed meanwhile: the table that is now at its place.
            guard let block = MystTables.table(at: min(range.location, text.length), in: textView.string) else {
                errorMessage = "The table is no longer in the page; nothing was changed."
                return
            }
            range = block.range
        }
        let markdown = table.markdown
        guard markdown != text.substring(with: range), textView.replace(range, with: markdown, actionName: "Edit Table") else { return }
        let cursor = NSRange(location: range.location, length: 0)
        textView.setSelectedRange(cursor)
        textView.scrollRangeToVisible(cursor)
        textView.window?.makeFirstResponder(textView)
    }

    /// The Style screen at its tables, where the look of every table of the book is set.
    func showTableStyle() {
        tableAssistant = nil
        styleElementRequest = "tables"
        showSettings(.style)
    }
}
