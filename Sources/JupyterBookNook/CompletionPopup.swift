import AppKit
import ProjectIndex

/// The completion list under the cursor, styled after mockup 02: a white card with rows of icon,
/// name and place, the chosen row in the accent colour, and below a divider the target's title
/// with a snippet and the keys. It never takes keyboard focus; the text view forwards the keys.
@MainActor
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var items: [CompletionItem] = []
    private(set) var selectedIndex = 0
    /// Whether the list is shown (tracked here, so it also works off-screen in tests).
    private(set) var isShown = false
    /// Called when a row is clicked.
    var onAccept: ((Int) -> Void)?

    static let width: CGFloat = 470
    static let rowHeight: CGFloat = 30
    static let maxRows = 7
    private static let padding: CGFloat = 14

    private let panel: CompletionPanel
    private let card = CardView()
    private let scroll = NSScrollView()
    private let table = CompletionTable()
    private let divider = NSBox()
    private let preview = NSTextField(wrappingLabelWithString: "")
    private let hint = NSTextField(labelWithString: "↵ insert · ⇥ next · esc close")

    override init() {
        panel = CompletionPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.width = Self.width
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay

        divider.boxType = .separator
        preview.font = .systemFont(ofSize: 12)
        preview.maximumNumberOfLines = 3
        preview.lineBreakMode = .byTruncatingTail
        hint.font = .systemFont(ofSize: 11.5)
        hint.textColor = .secondaryLabelColor

        for view in [scroll, divider, preview, hint] as [NSView] { card.addSubview(view) }
        panel.contentView = card
    }

    /// Shows `items` under (or, near the bottom of the screen, above) `anchor`, a rectangle in
    /// screen coordinates around the start of the partial name.
    func show(_ items: [CompletionItem], anchor: NSRect, in window: NSWindow?) {
        let keepSelection = isShown && self.items.indices.contains(selectedIndex) && items.indices.contains(selectedIndex)
            && items[selectedIndex].title == self.items[selectedIndex].title
        self.items = items
        if !keepSelection { selectedIndex = 0 }
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        table.scrollRowToVisible(selectedIndex)
        isShown = true
        let size = layout()

        var origin = NSPoint(x: anchor.minX - 18, y: anchor.minY - size.height - 4)
        if let screen = window?.screen ?? NSScreen.main {
            if origin.y < screen.visibleFrame.minY { origin.y = anchor.maxY + 4 }
            origin.x = min(origin.x, screen.visibleFrame.maxX - size.width - 8)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if let window, panel.parent == nil {
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = max(0, min(items.count - 1, selectedIndex + delta))
        table.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        table.scrollRowToVisible(selectedIndex)
        refreshPreview()
    }

    /// Lays out the card for the current items and selection; returns its size.
    @discardableResult
    private func layout() -> NSSize {
        let width = Self.width
        let listHeight = CGFloat(min(Self.maxRows, max(items.count, 1))) * Self.rowHeight
        let text = previewText()
        preview.attributedStringValue = text ?? NSAttributedString()
        let textWidth = width - 2 * Self.padding
        let previewHeight = text.map { ceil($0.boundingRect(with: NSSize(width: textWidth, height: 60), options: [.usesLineFragmentOrigin]).height) } ?? 0
        let hintHeight: CGFloat = 16
        let footer = (previewHeight > 0 ? previewHeight + 6 : 0) + hintHeight + 20
        let height = listHeight + 1 + footer

        // The card is flipped: y grows downwards. The rows start at the top edge, as in the mockup.
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: listHeight)
        divider.frame = NSRect(x: 0, y: listHeight, width: width, height: 1)
        var y = listHeight + 1 + 10
        preview.isHidden = previewHeight == 0
        preview.frame = NSRect(x: Self.padding, y: y, width: textWidth, height: previewHeight)
        if previewHeight > 0 { y += previewHeight + 6 }
        hint.frame = NSRect(x: Self.padding, y: y, width: textWidth, height: hintHeight)
        card.frame = NSRect(x: 0, y: 0, width: width, height: height)
        return NSSize(width: width, height: height)
    }

    /// "**Convergence** — “For convex f with …”" for the chosen item.
    private func previewText() -> NSAttributedString? {
        guard items.indices.contains(selectedIndex) else { return nil }
        let item = items[selectedIndex]
        guard item.previewTitle != nil || item.detail != nil else { return nil }
        let text = NSMutableAttributedString()
        if let title = item.previewTitle, !title.isEmpty {
            text.append(NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor]))
        }
        if let detail = item.detail, !detail.isEmpty {
            if text.length > 0 { text.append(NSAttributedString(string: " — ", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])) }
            text.append(NSAttributedString(string: detail, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return text
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard row >= 0 else { return }
        // After the table's click handling: accepting can reload the table (a role's label list
        // follows), which inside its own callback is a reentrant operation.
        DispatchQueue.main.async { [weak self] in self?.onAccept?(row) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: CompletionCell.identifier, owner: nil) as? CompletionCell) ?? CompletionCell()
        cell.configure(items[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        CompletionRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0, table.selectedRow != selectedIndex else { return }
        selectedIndex = table.selectedRow
        // Not inside the table's own callback: changing views there is a reentrant operation,
        // which AppKit warns about (and plans to turn into an assertion).
        DispatchQueue.main.async { [weak self] in self?.refreshPreview() }
    }

    /// Updates the text under the list for the chosen row, resizing the card if needed.
    private func refreshPreview() {
        guard isShown else { return }
        let height = panel.frame.height
        let size = layout()
        if size.height != height {
            var frame = panel.frame
            frame.origin.y += height - size.height
            frame.size = size
            panel.setFrame(frame, display: true)
        }
    }
}

// MARK: - Views

/// The white card: rounded, with a hairline border.
private final class CardView: NSView {
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    override var wantsUpdateLayer: Bool { true }
}

/// The chosen row is filled with the accent colour, although the list never has focus.
private final class CompletionRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        bounds.fill()
    }
}

/// One row: an outlined icon box, the name in monospace, and the place at the right.
private final class CompletionCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("CompletionCell")

    private let iconBox = NSView()
    private let glyph = NSTextField(labelWithString: "")
    private let symbol = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let trailing = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: CompletionPopup.width, height: CompletionPopup.rowHeight))
        identifier = Self.identifier
        iconBox.wantsLayer = true
        iconBox.layer?.cornerRadius = 4
        iconBox.layer?.borderWidth = 1
        glyph.font = .systemFont(ofSize: 12, weight: .medium)
        glyph.alignment = .center
        symbol.symbolConfiguration = .init(pointSize: 10, weight: .medium)
        title.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        title.lineBreakMode = .byTruncatingTail
        trailing.font = .systemFont(ofSize: 12)
        trailing.alignment = .right
        trailing.lineBreakMode = .byTruncatingMiddle
        for view in [iconBox, title, trailing] as [NSView] { addSubview(view) }
        iconBox.addSubview(glyph)
        iconBox.addSubview(symbol)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ item: CompletionItem) {
        title.stringValue = item.title
        trailing.stringValue = item.trailing ?? ""
        // Sections get "§" as in the mockup; other kinds an SF Symbol.
        let name: String?
        switch item.kind {
        case .section, .page: name = nil
        case .equation: name = "function"
        case .figure: name = "photo"
        case .table: name = "tablecells"
        case .code: name = "chevron.left.forwardslash.chevron.right"
        case .theorem: name = "text.book.closed"
        case .directive: name = "curlybraces"
        case .role: name = "textformat"
        case .citation: name = "quote.opening"
        case .file: name = "doc"
        case .option: name = "slider.horizontal.3"
        }
        glyph.stringValue = item.kind == .page ? "¶" : "§"
        glyph.isHidden = name != nil
        symbol.image = name.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        symbol.isHidden = name == nil
        updateColors()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        iconBox.frame = NSRect(x: 14, y: (height - 18) / 2, width: 18, height: 18)
        glyph.frame = NSRect(x: 0, y: 1, width: 18, height: 16)
        symbol.frame = iconBox.bounds.insetBy(dx: 3, dy: 3)
        // The field's own fitting size includes its inner margins.
        trailing.sizeToFit()
        let trailingWidth = min(190, ceil(trailing.frame.width))
        trailing.frame = NSRect(x: bounds.width - 14 - trailingWidth, y: (height - 16) / 2, width: trailingWidth, height: 16)
        title.frame = NSRect(x: 42, y: (height - 17) / 2, width: trailing.frame.minX - 50, height: 17)
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        title.textColor = selected ? .white : .labelColor
        trailing.textColor = selected ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor
        glyph.textColor = selected ? .white : .secondaryLabelColor
        symbol.contentTintColor = selected ? .white : .secondaryLabelColor
        iconBox.layer?.borderColor = (selected ? NSColor.white.withAlphaComponent(0.8) : NSColor.tertiaryLabelColor).cgColor
    }
}

/// Never becomes key, so the text view keeps the keyboard while the list is shown.
private final class CompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Accepts the first click, although its panel is never the key window.
private final class CompletionTable: NSTableView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
