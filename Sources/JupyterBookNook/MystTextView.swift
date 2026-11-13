import AppKit
import BookModel
import MystSyntax
import ProjectIndex

/// The editor's text view: completion for MyST names, labels, citations, paths and options in
/// a list under the cursor. Typing goes on into the text and narrows the list; ↑ ↓ or ⇥ ⇧⇥
/// choose, Return accepts, Esc closes it (or opens it when it is closed).
final class MystTextView: NSTextView {
    /// Supplies suggestions for a context and the character after the cursor.
    var completionProvider: ((CompletionContext, String) -> [CompletionItem])?
    /// Code and math, where completion stays off.
    var noCompletionRanges: [NSRange] = []

    let completionPopup = CompletionPopup()
    private var lastInserted: String?
    /// Characters after which a name, label, key, path or option usually follows.
    static let triggers: Set<Character> = ["{", "`", "@", "#", "(", ":", "/", ","]

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        completionPopup.onAccept = { [weak self] index in self?.acceptCompletion(at: index) }
        foldingLayoutManager?.onLayoutCompleted = { [weak self] in self?.scheduleBadgePlacement() }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        completionPopup.onAccept = { [weak self] index in self?.acceptCompletion(at: index) }
    }

    /// The completion context at the cursor, unless the cursor is in code or math.
    func completionContext() -> CompletionContext? {
        let selection = selectedRange()
        guard selection.length == 0 else { return nil }
        let cursor = selection.location
        if noCompletionRanges.contains(where: { $0.location < cursor && cursor <= NSMaxRange($0) }) { return nil }
        return CompletionContext.at(cursor, in: string)
    }

    // MARK: Typing

    override func insertText(_ string: Any, replacementRange: NSRange) {
        lastInserted = (string as? String) ?? (string as? NSAttributedString)?.string
        super.insertText(string, replacementRange: replacementRange)
    }

    override func didChangeText() {
        super.didChangeText()
        adjustTabStops()
        let typed = lastInserted
        lastInserted = nil
        guard !hasMarkedText() else { return }
        let isTrigger = typed.map { $0.count == 1 && Self.triggers.contains($0.first!) } ?? false
        // While the list is shown, every change (typing, deleting) narrows or widens it.
        if completionPopup.isShown || isTrigger {
            updateCompletion(open: isTrigger)
        }
    }

    /// Shows, refreshes or hides the list for the context at the cursor. With `open: false`
    /// a hidden list stays hidden.
    func updateCompletion(open: Bool) {
        guard let context = completionContext(), let completionProvider else {
            hideCompletion()
            return
        }
        let ns = string as NSString
        let cursor = selectedRange().location
        let next = cursor < ns.length ? ns.substring(with: NSRange(location: cursor, length: 1)) : ""
        let items = Array(completionProvider(context, next).prefix(200))
        guard !items.isEmpty else {
            hideCompletion()
            return
        }
        guard completionPopup.isShown || open else { return }
        completionPopup.show(items, anchor: screenRect(at: context.range.location), in: window)
    }

    func hideCompletion() {
        completionPopup.hide()
    }

    /// Accepts a suggestion: replaces the partial name, adds the suffix (e.g. "}" or "}``") and
    /// places the cursor. After a role name, the list for its content opens at once.
    func acceptCompletion(at index: Int) {
        guard completionPopup.items.indices.contains(index), let context = completionContext() else {
            hideCompletion()
            return
        }
        let item = completionPopup.items[index]
        hideCompletion()
        let text = item.insert + item.suffix
        undoManager?.beginUndoGrouping()
        insertText(text, replacementRange: context.range)
        let end = context.range.location + (text as NSString).length
        if context.kind == .directiveName { addClosingFence(below: end) }
        undoManager?.endUndoGrouping()
        setSelectedRange(NSRange(location: end - item.cursorBack, length: 0))
        if item.cursorBack > 0 || item.suffix == "}" {
            updateCompletion(open: true)
        }
    }

    /// After choosing a directive on a fence line: a closing fence with the same marker and
    /// indentation on a new line beneath, unless the next line already is one.
    private func addClosingFence(below location: Int) {
        let ns = string as NSString
        let line = ns.lineRange(for: NSRange(location: location, length: 0))
        let lineText = ns.substring(with: line)
        guard let match = lineText.range(of: #"^[ \t]*(`{3,}|:{3,})"#, options: .regularExpression) else { return }
        let opener = String(lineText[match])
        let indent = String(opener.prefix { $0 == " " || $0 == "\t" })
        let marker = String(opener.dropFirst(indent.count))
        let lineEnd = NSMaxRange(line) - (lineText.hasSuffix("\n") ? 1 : 0)
        if NSMaxRange(line) < ns.length {
            let next = ns.substring(with: ns.lineRange(for: NSRange(location: NSMaxRange(line), length: 0)))
            if next.trimmingCharacters(in: .whitespacesAndNewlines) == marker { return }
        }
        insertText("\n" + indent + marker, replacementRange: NSRange(location: lineEnd, length: 0))
    }

    /// Where the list goes: the line of `location`, in screen coordinates.
    private func screenRect(at location: Int) -> NSRect {
        let rect = firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
        return rect.isEmpty && rect.origin == .zero ? (window?.frame ?? .zero) : rect
    }

    // MARK: Keys while the list is shown

    override func doCommand(by selector: Selector) {
        if completionPopup.isShown {
            switch selector {
            case #selector(moveDown(_:)):
                completionPopup.move(1)
                return
            case #selector(moveUp(_:)):
                completionPopup.move(-1)
                return
            case #selector(pageDown(_:)), #selector(scrollPageDown(_:)):
                completionPopup.move(8)
                return
            case #selector(pageUp(_:)), #selector(scrollPageUp(_:)):
                completionPopup.move(-8)
                return
            case #selector(insertNewline(_:)):
                acceptCompletion(at: completionPopup.selectedIndex)
                return
            case #selector(insertTab(_:)):
                completionPopup.move(1)
                return
            case #selector(insertBacktab(_:)):
                completionPopup.move(-1)
                return
            case #selector(cancelOperation(_:)):
                hideCompletion()
                return
            case #selector(deleteBackward(_:)), #selector(deleteForward(_:)):
                break // the list follows the change (didChangeText)
            default:
                hideCompletion()
            }
        } else if !tabStops.isEmpty {
            switch selector {
            case #selector(insertTab(_:)):
                _ = moveToTabStop(1)
                return
            case #selector(insertBacktab(_:)):
                _ = moveToTabStop(-1)
                return
            case #selector(cancelOperation(_:)), #selector(insertNewline(_:)):
                // Esc ends the snippet; Return also types its newline.
                endTabStops()
                if selector == #selector(cancelOperation(_:)) { return }
            default:
                break
            }
        }
        super.doCommand(by: selector)
    }

    /// Esc (and ⌥Esc) open the list when it is closed.
    override func complete(_ sender: Any?) {
        updateCompletion(open: true)
    }

    override func resignFirstResponder() -> Bool {
        hideCompletion()
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        hideCompletion()
        endTabStops()
        super.mouseDown(with: event)
    }

    // MARK: Table assistant badges

    /// Where the page's tables start; each has a pink “TA” circle at the right of its first line
    /// that opens the table assistant.
    var tableStarts: [Int] = [] {
        didSet { placeTableBadges() }
    }
    var onTableBadge: ((Int) -> Void)?
    private var tableBadges: [TableBadgeView] = []
    private var badgePlacementPending = false

    /// The badge of the table starting at `location`, at the right end of the text column; nil
    /// while that line is folded away.
    func tableBadgeRect(for location: Int) -> NSRect? {
        guard let layoutManager, let container = textContainer, location < (string as NSString).length else { return nil }
        if let folds = foldingLayoutManager?.folds, folds.contains(where: { $0.location < location && location <= NSMaxRange($0) }) { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: location)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        let size = TableBadgeView.size
        let origin = textContainerOrigin
        // Inside the text column, clear of the scroller at the right edge.
        let x = min(origin.x + container.size.width - size - 2, bounds.maxX - size - 20)
        return NSRect(x: x, y: origin.y + used.minY + (used.height - size) / 2, width: size, height: size).integral
    }

    func tableBadge(at point: NSPoint) -> Int? {
        tableBadges.first { !$0.isHidden && $0.frame.contains(point) }?.start
    }

    /// Puts a badge on each table's first line.
    func placeTableBadges() {
        while tableBadges.count < tableStarts.count {
            let badge = TableBadgeView()
            badge.onClick = { [weak self] start in self?.onTableBadge?(start) }
            addSubview(badge)
            tableBadges.append(badge)
        }
        while tableBadges.count > tableStarts.count { tableBadges.removeLast().removeFromSuperview() }
        for (badge, start) in zip(tableBadges, tableStarts) {
            badge.start = start
            if let rect = tableBadgeRect(for: start) {
                if badge.frame != rect { badge.frame = rect }
                badge.isHidden = false
            } else {
                badge.isHidden = true
            }
        }
    }

    /// The badges follow their lines once the text is laid out again (folding, the book view, a
    /// new width) or the view's size or margins change; not on other redraws, such as the
    /// blinking cursor.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scheduleBadgePlacement()
    }

    override var textContainerInset: NSSize {
        didSet { scheduleBadgePlacement() }
    }

    private func scheduleBadgePlacement() {
        guard !tableStarts.isEmpty, !badgePlacementPending else { return }
        badgePlacementPending = true
        DispatchQueue.main.async { [weak self] in
            self?.badgePlacementPending = false
            self?.placeTableBadges()
        }
    }

    // MARK: Inserting snippets, figures and links

    /// Inserts `body` in place of `range` as one undo step and selects `selection` (relative to
    /// `body`). Text of several lines starts on its own line and takes the indentation of the line
    /// it goes into; the rest of that line goes below it.
    func insert(_ body: String, selecting selection: NSRange, replacing range: NSRange, actionName: String) {
        insert(body, stops: [selection], replacing: range, actionName: actionName)
    }

    /// Like `insert(_:selecting:…)` with snippet tab stops: the first is selected, ⇥ and ⇧⇥ move
    /// between them until the last is reached, Esc is pressed or the cursor is clicked elsewhere.
    func insert(_ body: String, stops: [NSRange], replacing range: NSRange, actionName: String) {
        let text = string as NSString
        // Mark each stop with a pair of private-use characters, so it can be found again after indenting.
        let marked = NSMutableString(string: body)
        let order = stops.indices.sorted { (stops[$0].location, stops[$0].length) > (stops[$1].location, stops[$1].length) }
        for index in order {
            marked.insert(Self.mark(index, end: true), at: NSMaxRange(stops[index]))
            marked.insert(Self.mark(index, end: false), at: stops[index].location)
        }
        var insertion = marked as String

        let lineStart = text.lineRange(for: NSRange(location: range.location, length: 0)).location
        let before = text.substring(with: NSRange(location: lineStart, length: range.location - lineStart))
        let indent = String(before.prefix(while: { $0 == " " || $0 == "\t" }))
        if insertion.contains("\n") {
            var lines = insertion.components(separatedBy: "\n")
            for i in lines.indices.dropFirst() where !lines[i].isEmpty { lines[i] = indent + lines[i] }
            insertion = lines.joined(separator: "\n")
            if !before.trimmingCharacters(in: .whitespaces).isEmpty { insertion = "\n" + indent + insertion }
            // The rest of the line goes below the block, with the line's indentation.
            let lineEnd = text.lineRange(for: NSRange(location: range.upperBound, length: 0))
            let after = text.substring(with: NSRange(location: range.upperBound, length: NSMaxRange(lineEnd) - range.upperBound))
            if !after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !insertion.hasSuffix("\n") { insertion += "\n" }
                insertion += indent
            }
        }
        // Remove the marks, noting where each stop ended up.
        var clean = ""
        var starts: [Int: Int] = [:], ends: [Int: Int] = [:]
        var length = 0
        for scalar in insertion.unicodeScalars {
            if let (index, isEnd) = Self.readMark(scalar) {
                if isEnd { ends[index] = length } else { starts[index] = length }
            } else {
                clean.unicodeScalars.append(scalar)
                length += scalar.utf16.count
            }
        }
        let placed = stops.indices.map { NSRange(location: range.location + starts[$0, default: 0], length: ends[$0, default: 0] - starts[$0, default: 0]) }

        guard replace(range, with: clean, actionName: actionName) else { return }
        let selected = placed.first ?? NSRange(location: range.location + length, length: 0)
        setSelectedRange(selected)
        scrollRangeToVisible(selected)
        window?.makeFirstResponder(self)
        if placed.count > 1 {
            tabStops = placed
            currentStop = 0
            showTabStops()
        }
    }

    /// Changes the text to `newText` as one undo step, replacing only the part that differs (so
    /// the cursor and scroll position stay). Used by the inspector's forms.
    func replaceText(with newText: String, actionName: String) {
        let old = string as NSString
        let new = newText as NSString
        guard old != new else { return }
        var prefix = 0
        let shorter = min(old.length, new.length)
        while prefix < shorter, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix, old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        let range = NSRange(location: prefix, length: old.length - prefix - suffix)
        let replacement = new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
        let selection = selectedRange()
        guard replace(range, with: replacement, actionName: actionName) else { return }
        // Keep the cursor on the same text: shift it when the change was before it.
        let delta = (replacement as NSString).length - range.length
        if selection.location >= NSMaxRange(range) {
            setSelectedRange(NSRange(location: selection.location + delta, length: selection.length))
        } else if selection.location > range.location {
            setSelectedRange(NSRange(location: min(selection.location, prefix + (replacement as NSString).length), length: 0))
        }
    }

    /// Replaces `range` with `replacement` as one undo step named `actionName`, as typing would.
    /// False when the text view refuses the change.
    @discardableResult
    func replace(_ range: NSRange, with replacement: String, actionName: String) -> Bool {
        guard shouldChangeText(in: range, replacementString: replacement) else { return false }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
        undoManager?.setActionName(actionName)
        return true
    }

    private static func mark(_ index: Int, end: Bool) -> String {
        String(Character(Unicode.Scalar(0xE100 + UInt32(index) * 2 + (end ? 1 : 0))!))
    }

    private static func readMark(_ scalar: Unicode.Scalar) -> (Int, Bool)? {
        guard (0xE100..<0xE300).contains(scalar.value) else { return nil }
        let offset = Int(scalar.value - 0xE100)
        return (offset / 2, offset % 2 == 1)
    }

    // MARK: Folding

    var foldingLayoutManager: FoldingLayoutManager? { layoutManager as? FoldingLayoutManager }

    /// The text a folded directive hides: everything after its opening line up to the end of its
    /// closing fence. Nil for a directive of one line.
    static func foldRange(of block: DirectiveBlock) -> NSRange? {
        let start = NSMaxRange(block.openingLine)
        let end = NSMaxRange(block.range)
        return end > start + 1 ? NSRange(location: start, length: end - start) : nil
    }

    /// The front matter below its opening `---`: from that line's newline to the end of the
    /// closing `---` (or `...`). Nil when the page has none.
    static func frontMatterFoldRange(in text: String) -> NSRange? {
        let ns = text as NSString
        guard ns.length > 4, text.hasPrefix("---") else { return nil }
        let first = ns.lineRange(for: NSRange(location: 0, length: 0))
        guard ns.substring(with: first).trimmingCharacters(in: .whitespacesAndNewlines) == "---" else { return nil }
        var location = NSMaxRange(first)
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            let content = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if content == "---" || content == "..." {
                var end = NSMaxRange(line)
                if end > line.location, ns.character(at: end - 1) == 10 { end -= 1 }
                let start = NSMaxRange(first) - 1 // the newline after the opening ---
                return end > start + 1 ? NSRange(location: start, length: end - start) : nil
            }
            location = NSMaxRange(line)
        }
        return nil
    }

    /// The option lines of each directive, folded into its opening line.
    static func optionFoldRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        return DirectiveBlocks.all(in: text).compactMap { block in
            guard let last = block.options.last else { return nil }
            let start = NSMaxRange(block.openingLine)
            var end = NSMaxRange(last.line)
            if end > start, end <= ns.length, ns.character(at: end - 1) == 10 { end -= 1 }
            return end > start + 1 ? NSRange(location: start, length: end - start) : nil
        }
    }

    /// Folds (or unfolds) the front matter and the directive options, leaving other folds alone.
    func applyYAMLFolds(frontMatter: Bool, options: Bool) {
        guard let manager = foldingLayoutManager else { return }
        let front = Self.frontMatterFoldRange(in: string)
        let optionRanges = Self.optionFoldRanges(in: string)
        var folds = manager.folds.filter { $0 != front && !optionRanges.contains($0) }
        if frontMatter, let front { folds.append(front) }
        if options { folds += optionRanges }
        // The cursor stays visible: folds around it are left open.
        let cursor = selectedRange().location
        folds = folds.filter { !(cursor > $0.location && cursor <= NSMaxRange($0)) || manager.folds.contains($0) }
        manager.setFolds(folds)
    }

    /// Directives that can be folded, by the start of their opening line.
    var foldableBlocks: [DirectiveBlock] {
        DirectiveBlocks.all(in: string).filter { Self.foldRange(of: $0) != nil }
    }

    /// Folds or unfolds the directive whose opening line starts at `lineStart` (fold markers).
    func toggleFold(lineStart: Int) {
        if lineStart == 0, let manager = foldingLayoutManager, let front = Self.frontMatterFoldRange(in: string) {
            if manager.isFolded(front) { manager.unfold(front) } else { manager.fold(front) }
            return
        }
        guard let manager = foldingLayoutManager,
              let block = foldableBlocks.first(where: { $0.openingLine.location == lineStart }),
              let range = Self.foldRange(of: block) else { return }
        if manager.isFolded(range) {
            manager.unfold(range)
        } else {
            foldAndKeepCursor(range, block: block)
        }
    }

    /// Folds the innermost directive around the cursor (View › Fold).
    func foldAtCursor() {
        let location = selectedRange().location
        guard let block = foldableBlocks.filter({ $0.range.location <= location && location <= NSMaxRange($0.range) })
                .min(by: { $0.range.length < $1.range.length }),
              let range = Self.foldRange(of: block) else { NSSound.beep(); return }
        foldAndKeepCursor(range, block: block)
    }

    /// Unfolds the fold on the cursor's line, or the folds inside the selection.
    func unfoldAtCursor() {
        guard let manager = foldingLayoutManager else { return }
        let selection = selectedRange()
        let lineEnd = NSMaxRange((string as NSString).lineRange(for: NSRange(location: selection.location, length: 0)))
        let hit = manager.folds.filter { fold in
            NSIntersectionRange(fold, selection).length > 0 || (fold.location >= selection.location && fold.location <= lineEnd)
        }
        guard !hit.isEmpty else { NSSound.beep(); return }
        manager.setFolds(manager.folds.filter { !hit.contains($0) })
    }

    func foldAll() {
        guard let manager = foldingLayoutManager else { return }
        // Outer directives only; folding them hides the inner ones.
        let blocks = foldableBlocks
        let outer = blocks.filter { block in !blocks.contains { $0 != block && $0.range.location < block.range.location && NSMaxRange($0.range) >= NSMaxRange(block.range) } }
        manager.setFolds(outer.compactMap(Self.foldRange(of:)))
        // The cursor may now be hidden; put it on the visible line.
        if let fold = manager.fold(containing: selectedRange().location) {
            setSelectedRange(NSRange(location: fold.location, length: 0))
        }
    }

    func unfoldAll() {
        foldingLayoutManager?.setFolds([])
    }

    private func foldAndKeepCursor(_ range: NSRange, block: DirectiveBlock) {
        foldingLayoutManager?.fold(range)
        let selection = selectedRange()
        if NSIntersectionRange(selection, range).length > 0 || (selection.location > range.location && selection.location <= NSMaxRange(range)) {
            setSelectedRange(NSRange(location: range.location, length: 0))
        }
    }

    // MARK: Snippet tab stops

    /// Ranges of the inserted snippet's stops while ⇥ moves between them; empty otherwise.
    private(set) var tabStops: [NSRange] = []
    private var currentStop = 0
    private var pendingEdit: (range: NSRange, length: Int)?

    /// Moves to the next (or previous) stop. Returns false when there is no snippet session.
    func moveToTabStop(_ offset: Int) -> Bool {
        guard !tabStops.isEmpty else { return false }
        let next = currentStop + offset
        guard next >= 0 else { return true }
        guard next < tabStops.count else {
            // Past the last stop: the cursor goes to its end and the session ends.
            let last = tabStops[tabStops.count - 1]
            endTabStops()
            setSelectedRange(NSRange(location: NSMaxRange(last), length: 0))
            return true
        }
        currentStop = next
        setSelectedRange(tabStops[next])
        scrollRangeToVisible(tabStops[next])
        showTabStops()
        return true
    }

    func endTabStops() {
        guard !tabStops.isEmpty else { return }
        tabStops = []
        showTabStops()
    }

    /// The other stops get a faint background, so it is clear where ⇥ goes.
    private func showTabStops() {
        guard let layoutManager else { return }
        let full = NSRange(location: 0, length: (string as NSString).length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        let color = MystHighlighter.accent.withAlphaComponent(0.13)
        for (index, stop) in tabStops.enumerated() where index != currentStop && NSMaxRange(stop) <= full.length {
            // An empty stop shows as the character after it, so it can still be seen.
            let shown = stop.length > 0 ? stop : NSRange(location: stop.location, length: stop.location < full.length ? 1 : 0)
            layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: shown)
        }
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let allowed = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        if allowed, !tabStops.isEmpty {
            pendingEdit = (affectedCharRange, (replacementString as NSString?)?.length ?? 0)
        }
        return allowed
    }

    /// Keeps the stops on their text while typing: an edit inside a stop grows or shrinks it, one
    /// before a stop shifts it; an edit across a stop's edge ends the session.
    private func adjustTabStops() {
        guard let edit = pendingEdit else { return }
        pendingEdit = nil
        let delta = edit.length - edit.range.length
        var adjusted: [NSRange] = []
        for (index, stop) in tabStops.enumerated() {
            let inside = edit.range.location >= stop.location && NSMaxRange(edit.range) <= NSMaxRange(stop)
            if inside, index == currentStop || edit.range.length > 0 || stop.length > 0 {
                adjusted.append(NSRange(location: stop.location, length: stop.length + delta))
            } else if NSMaxRange(edit.range) <= stop.location {
                adjusted.append(NSRange(location: stop.location + delta, length: stop.length))
            } else if edit.range.location >= NSMaxRange(stop) {
                adjusted.append(stop)
            } else {
                endTabStops()
                return
            }
        }
        tabStops = adjusted
        showTabStops()
    }

    // MARK: Dropping files and pages

    /// What a drop inserts: text, the part of it to select, and the undo name.
    struct DropInsertion {
        var text: String
        var selection: NSRange
        var actionName: String
    }

    /// Something dropped on the editor: a file from outside, or a page or image from the sidebar
    /// (its drag payload, e.g. "file:images/plot.png" or "toc:<id>").
    enum DropItem {
        case file(URL)
        case sidebar(String)
        /// An image pasted from the clipboard (a screenshot, an image copied in Preview), as PNG.
        case imageData(Data)
    }

    /// Turns dropped items into text; `plain` is true while Shift is held. Nil leaves the drop to
    /// the text view (plain text is inserted as usual).
    var dropProvider: ((_ items: [DropItem], _ plain: Bool) -> DropInsertion?)?

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL]
    }

    override func dragOperation(for dragInfo: NSDraggingInfo, type: NSPasteboard.PasteboardType) -> NSDragOperation {
        type == .fileURL ? .copy : super.dragOperation(for: dragInfo, type: type)
    }

    /// `NOOK_DEBUG_DROP=1` prints what is dragged over the editor, for diagnosing drag and drop.
    private static let logsDrops = ProcessInfo.processInfo.environment["NOOK_DEBUG_DROP"] != nil

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = super.draggingEntered(sender)
        let custom = customDropOperation(sender)
        if Self.logsDrops {
            print("[drop] entered types=\(sender.draggingPasteboard.types ?? []) mask=\(sender.draggingSourceOperationMask.rawValue) textView=\(operation.rawValue) custom=\(custom?.rawValue ?? 0)")
        }
        return custom ?? operation
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = super.draggingUpdated(sender)
        return customDropOperation(sender) ?? operation
    }

    /// Pages from the sidebar are dragged as a move (the list reorders them), which a text view
    /// refuses; files and sidebar items are accepted with whatever operation the source allows.
    private func customDropOperation(_ sender: NSDraggingInfo) -> NSDragOperation? {
        if (sender.draggingSource as AnyObject?) === self { return nil }
        let pasteboard = sender.draggingPasteboard
        let hasFiles = pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        let hasSidebarItem = (pasteboard.readObjects(forClasses: [NSString.self]) as? [String])?
            .contains { $0.hasPrefix("toc:") || $0.hasPrefix("file:") } ?? false
        guard hasFiles || hasSidebarItem else { return nil }
        let mask = sender.draggingSourceOperationMask
        return [NSDragOperation.copy, .generic, .move, .link].first { mask.contains($0) }
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        customDropOperation(sender) != nil || super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if Self.logsDrops { print("[drop] perform types=\(sender.draggingPasteboard.types ?? [])") }
        // Moving text inside the editor stays the text view's business.
        if (sender.draggingSource as AnyObject?) === self { return super.performDragOperation(sender) }
        let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        return handleDrop(sender.draggingPasteboard, at: index, plain: NSEvent.modifierFlags.contains(.shift))
            || super.performDragOperation(sender)
    }

    /// Inserts what `pasteboard` holds at `index` if it is a file or a sidebar item; false leaves
    /// it to the text view.
    func handleDrop(_ pasteboard: NSPasteboard, at index: Int, plain: Bool) -> Bool {
        handleDrop(pasteboard, replacing: NSRange(location: index, length: 0), plain: plain)
    }

    // MARK: Pasting images

    /// ⌘V with an image on the clipboard: image files and image data are added to images/ and
    /// inserted as a {figure} (with ⇧ held, as just `![](…)`). Text pastes as usual.
    override func paste(_ sender: Any?) {
        if !pasteImage(plain: false) { super.paste(sender) }
    }

    /// Pastes an image from the clipboard as a figure, or as just the image with `plain`
    /// (Edit › Paste Image Only, ⇧⌘V). False when the clipboard holds no image.
    @discardableResult
    func pasteImage(plain: Bool) -> Bool {
        let pasteboard = NSPasteboard.general
        guard Self.hasImageFiles(pasteboard) || Self.imageData(pasteboard) != nil else { return false }
        return handleDrop(pasteboard, replacing: selectedRange(), plain: plain, allowsImageData: true)
    }

    static func hasImageFiles(_ pasteboard: NSPasteboard) -> Bool {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return !urls.isEmpty && urls.allSatisfy { BookProject.importKind(of: $0) == .image }
    }

    /// PNG data for an image on the pasteboard that is not also text (copying from a web page
    /// puts both; then the text wins).
    static func imageData(_ pasteboard: NSPasteboard) -> Data? {
        let types = pasteboard.types ?? []
        guard !types.contains(.string), !types.contains(.fileURL) else { return nil }
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Inserts what `pasteboard` holds in place of `range`; false leaves it to the text view.
    func handleDrop(_ pasteboard: NSPasteboard, replacing range: NSRange, plain: Bool, allowsImageData: Bool = false) -> Bool {
        if allowsImageData, let data = Self.imageData(pasteboard) {
            guard let insertion = dropProvider?([.imageData(data)], plain) else { return false }
            insert(insertion.text, selecting: insertion.selection, replacing: range, actionName: insertion.actionName == "Insert Figure" ? "Paste Figure" : "Paste Image")
            return true
        }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        var items: [DropItem] = urls.map { .file($0) }
        if items.isEmpty, let strings = pasteboard.readObjects(forClasses: [NSString.self]) as? [String] {
            items = strings.filter { $0.hasPrefix("toc:") || $0.hasPrefix("file:") }.map { .sidebar($0) }
        }
        guard !items.isEmpty, let insertion = dropProvider?(items, plain) else { return false }
        insert(insertion.text, selecting: insertion.selection, replacing: range, actionName: insertion.actionName)
        return true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { hideCompletion() }
        super.viewWillMove(toWindow: newWindow)
    }
}

/// The pink “TA” circle next to a table; a click opens the table assistant.
final class TableBadgeView: NSView {
    static let size: CGFloat = 22
    var start = 0
    var onClick: ((Int) -> Void)?
    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "Table Assistant: edit rows, columns, cells and style"
        setAccessibilityRole(.button)
        setAccessibilityLabel("Table Assistant")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let fill = dark ? NSColor(srgbRed: 0.42, green: 0.2, blue: 0.3, alpha: 1) : NSColor(srgbRed: 1, green: 0.84, blue: 0.9, alpha: 1)
        let ink = dark ? NSColor(srgbRed: 1, green: 0.8, blue: 0.88, alpha: 1) : NSColor(srgbRed: 0.68, green: 0.16, blue: 0.4, alpha: 1)
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        (isHovered ? fill.blended(withFraction: 0.18, of: ink) ?? fill : fill).setFill()
        circle.fill()
        if isHovered {
            ink.withAlphaComponent(0.6).setStroke()
            circle.lineWidth = 1
            circle.stroke()
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5, weight: .heavy), .foregroundColor: ink]
        let label = "TA" as NSString
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        isHovered = false
        onClick?(start)
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?(start)
        return true
    }
}
