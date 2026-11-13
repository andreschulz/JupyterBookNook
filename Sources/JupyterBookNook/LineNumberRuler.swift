import AppKit
import MystSyntax

/// The column left of the editor: line numbers (Settings › Editor › Line numbers) and triangles
/// that fold directives and code cells. Counts lines of the file, not wrapped rows: a wrapped
/// paragraph gets one number. Lines inside a folded block are skipped. TextKit 1 only.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    /// Character offsets where lines start, rebuilt when the text changes.
    private var lineStarts: [Int] = [0]
    /// Opening lines of directives that can be folded, by line start.
    private var foldableLines: Set<Int> = []
    static let foldColumn: CGFloat = 14

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        (textView.layoutManager as? FoldingLayoutManager)?.onFoldsChanged = { [weak self] in self?.needsDisplay = true }
        textChanged()
    }

    required init(coder: NSCoder) {
        fatalError("not used")
    }

    private var settings: EditorSettings { .shared }

    /// Called by the editor after every change of the text (typing, reloads, settings).
    func textChanged() {
        guard let textView else { return }
        // A newline at the very end starts one more (empty) line, as in the editor.
        let starts = NSTextView.lineStarts(of: textView.string)
        lineStarts = starts
        foldableLines = settings.showsFoldMarkers ? Set((textView as? MystTextView)?.foldableBlocks.map(\.openingLine.location) ?? []) : []
        if settings.showsFoldMarkers, MystTextView.frontMatterFoldRange(in: textView.string) != nil { foldableLines.insert(0) }
        var width: CGFloat = settings.showsFoldMarkers ? Self.foldColumn + 4 : 0
        if settings.showsLineNumbers {
            let digits = max(3, String(starts.count).count)
            width += CGFloat(digits) * (font.pointSize * 0.62) + 12
        }
        width = max(width, 8)
        if abs(ruleThickness - width) > 0.5 { ruleThickness = width }
        needsDisplay = true
    }

    private var font: NSFont {
        let size = max(9, (textView?.font?.pointSize ?? 13) - 2)
        return .monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    override var isFlipped: Bool { true }

    /// Each visible line's start and its rect in the ruler, skipping lines hidden by a fold.
    private func visibleLines() -> [(line: Int, start: Int, rect: NSRect)] {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return [] }
        let folds = (layoutManager as? FoldingLayoutManager)?.folds ?? []
        let glyphs = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let offset = convert(NSPoint.zero, from: textView).y
        let length = (textView.string as NSString).length
        var result: [(Int, Int, NSRect)] = []
        var line = NSTextView.lineIndex(of: characters.location, in: lineStarts)
        while line < lineStarts.count {
            let start = lineStarts[line]
            if start > NSMaxRange(characters) { break }
            if folds.contains(where: { start > $0.location && start <= NSMaxRange($0) }) {
                line += 1
                continue
            }
            var rect: NSRect
            if start >= length {
                rect = layoutManager.extraLineFragmentRect
            } else {
                rect = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: start), effectiveRange: nil)
            }
            rect.origin.y += textView.textContainerOrigin.y + offset
            result.append((line, start, rect))
            line += 1
        }
        return result
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView else { return }
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        let cursor = textView.selectedRange().location
        let cursorLine = NSTextView.lineIndex(of: cursor, in: lineStarts)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        let current: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let folds = (textView.layoutManager as? FoldingLayoutManager)?.folds ?? []
        let numberRight = ruleThickness - (settings.showsFoldMarkers ? Self.foldColumn + 4 : 0) - 4
        for (line, start, lineRect) in visibleLines() {
            if settings.showsLineNumbers {
                let label = "\(line + 1)" as NSString
                let style = line == cursorLine ? current : attributes
                let size = label.size(withAttributes: style)
                // Centred in the line's first row.
                label.draw(at: NSPoint(x: numberRight - size.width, y: lineRect.minY + (lineRect.height - size.height) / 2), withAttributes: style)
            }
            if foldableLines.contains(start) {
                let isFolded = folds.contains { $0.location > start && $0.location <= start + lineLength(at: start) + 1 }
                drawTriangle(folded: isFolded, in: NSRect(x: ruleThickness - Self.foldColumn - 2, y: lineRect.minY, width: Self.foldColumn, height: lineRect.height))
            }
        }
    }

    private func lineLength(at start: Int) -> Int {
        guard let text = textView?.string as NSString? else { return 0 }
        var end = 0, contentsEnd = 0
        text.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
        return contentsEnd - start
    }

    private func drawTriangle(folded: Bool, in rect: NSRect) {
        let size: CGFloat = 7
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let path = NSBezierPath()
        if folded {
            path.move(to: NSPoint(x: center.x - size * 0.35, y: center.y - size / 2))
            path.line(to: NSPoint(x: center.x + size * 0.5, y: center.y))
            path.line(to: NSPoint(x: center.x - size * 0.35, y: center.y + size / 2))
        } else {
            path.move(to: NSPoint(x: center.x - size / 2, y: center.y - size * 0.35))
            path.line(to: NSPoint(x: center.x + size / 2, y: center.y - size * 0.35))
            path.line(to: NSPoint(x: center.x, y: center.y + size * 0.5))
        }
        path.close()
        (folded ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor).setFill()
        path.fill()
    }

    /// A click on a triangle folds or unfolds its directive.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let textView = textView as? MystTextView,
              let hit = visibleLines().first(where: { $0.rect.minY <= point.y && point.y < $0.rect.maxY }),
              foldableLines.contains(hit.start) else {
            super.mouseDown(with: event)
            return
        }
        textView.toggleFold(lineStart: hit.start)
        textChanged()
    }
}
