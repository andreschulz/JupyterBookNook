import AppKit

/// Folding for the editor (TextKit 1): the characters of a folded block are laid out as null
/// glyphs and their newlines take no space, so the block's opening line runs straight on to the
/// newline after its closing fence. A "⋯" badge is drawn after the opening line. The text itself
/// is never changed, so saving, undo and find are unaffected.
final class FoldingLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    /// Hidden character ranges, sorted and not overlapping: from the newline ending a block's
    /// opening line to the end of its closing fence.
    private(set) var folds: [NSRange] = []
    /// Called after folds change, so the line-number ruler can redraw.
    var onFoldsChanged: (() -> Void)?
    /// Called when lines were laid out again (typing, folding, the book view, a new width), so the
    /// table badges can follow their lines.
    var onLayoutCompleted: (() -> Void)?
    /// Characters the book view hides (markup outside the cursor's paragraph), and newlines it
    /// shows as spaces. Empty in the source view.
    private(set) var bookHidden = IndexSet()
    private(set) var bookJoins = IndexSet()
    /// Source text the book view shows as other text (math, resolved references), by the index of
    /// its first character. That character is laid out as a space as wide as the replacement,
    /// which is drawn there; the rest of the source is hidden.
    private(set) var bookReplacements: [Int: BookReplacement] = [:]
    /// Boxes, code panels and figures the book view draws behind the text.
    var bookBoxes: [BookBox] = [] {
        didSet {
            guard bookBoxes != oldValue, let length = textStorage?.length, length > 0 else { return }
            // Figures change the height of their lines.
            let figures = (oldValue + bookBoxes).filter { if case .figure = $0.kind { return true } else { return false } }
            for box in figures where NSMaxRange(box.range) <= length {
                invalidateLayout(forCharacterRange: box.range, actualCharacterRange: nil)
            }
            for container in textContainers { container.textView?.needsDisplay = true }
        }
    }

    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    func isFolded(_ range: NSRange) -> Bool {
        folds.contains(range)
    }

    /// The fold that hides `index`, if any.
    func fold(containing index: Int) -> NSRange? {
        folds.first { $0.location < index && index <= NSMaxRange($0) } ?? folds.first { NSLocationInRange(index, $0) }
    }

    func setFolds(_ newFolds: [NSRange]) {
        let length = textStorage?.length ?? 0
        let cleaned = newFolds.filter { $0.length > 0 && NSMaxRange($0) <= length }.sorted { $0.location < $1.location }
        // Folds inside a folded block are dropped; the outer one hides them anyway.
        var merged: [NSRange] = []
        for fold in cleaned where !merged.contains(where: { NSLocationInRange(fold.location, $0) }) { merged.append(fold) }
        let changed = Set(folds.map(\.description)).symmetricDifference(merged.map(\.description))
        guard !changed.isEmpty else { return }
        let affected = (folds + merged).reduce(nil as NSRange?) { union, range in union.map { NSUnionRange($0, range) } ?? range }
        folds = merged
        if let affected { refresh(affected) }
        onFoldsChanged?()
    }

    /// Sets what the book view hides; only the characters whose state changes are laid out again.
    func setBookPresentation(hidden: IndexSet, joins: IndexSet, replacements: [Int: BookReplacement] = [:]) {
        var changed = bookHidden.symmetricDifference(hidden).union(bookJoins.symmetricDifference(joins))
        for (index, replacement) in bookReplacements where replacements[index] != replacement { changed.insert(integersIn: index..<index + max(1, replacement.length)) }
        for (index, replacement) in replacements where bookReplacements[index] != replacement { changed.insert(integersIn: index..<index + max(1, replacement.length)) }
        bookHidden = hidden
        bookJoins = joins
        bookReplacements = replacements
        let length = textStorage?.length ?? 0
        for range in changed.rangeView where range.lowerBound < length {
            let target = NSRange(location: range.lowerBound, length: min(range.upperBound, length) - range.lowerBound)
            invalidateGlyphs(forCharacterRange: target, changeInLength: 0, actualCharacterRange: nil)
            invalidateLayout(forCharacterRange: target, actualCharacterRange: nil)
        }
        if !changed.isEmpty {
            for container in textContainers { container.textView?.needsDisplay = true }
        }
    }

    func fold(_ range: NSRange) { setFolds(folds + [range]) }
    func unfold(_ range: NSRange) { setFolds(folds.filter { $0 != range }) }

    private func refresh(_ range: NSRange) {
        let length = textStorage?.length ?? 0
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: length))
        // Include the opening line, whose badge appears or disappears.
        let start = max(0, clamped.location - 1)
        let target = NSRange(location: start, length: NSMaxRange(clamped) - start)
        invalidateGlyphs(forCharacterRange: target, changeInLength: 0, actualCharacterRange: nil)
        invalidateLayout(forCharacterRange: target, actualCharacterRange: nil)
        for container in textContainers { container.textView?.needsDisplay = true }
    }

    // MARK: Keeping folds on their text

    /// An edit that touches a folded block unfolds it; folds after an edit move with the text.
    override func processEditing(for textStorage: NSTextStorage, edited editMask: NSTextStorageEditActions, range newCharRange: NSRange,
                                 changeInLength delta: Int, invalidatedRange invalidatedCharRange: NSRange) {
        if editMask.contains(.editedCharacters), !bookHidden.isEmpty || !bookJoins.isEmpty {
            // Until the book view restyles the text, nothing that was edited is hidden.
            let original = NSRange(location: newCharRange.location, length: newCharRange.length - delta)
            bookHidden.remove(integersIn: original.location..<NSMaxRange(original))
            bookHidden.shift(startingAt: NSMaxRange(original), by: delta)
            bookJoins.remove(integersIn: original.location..<NSMaxRange(original))
            bookJoins.shift(startingAt: NSMaxRange(original), by: delta)
            var moved: [Int: BookReplacement] = [:]
            for (index, replacement) in bookReplacements {
                if index + replacement.length <= original.location {
                    moved[index] = replacement
                } else if index >= NSMaxRange(original) {
                    moved[index + delta] = replacement
                }
            }
            bookReplacements = moved
        }
        if editMask.contains(.editedCharacters), !folds.isEmpty {
            let original = NSRange(location: newCharRange.location, length: newCharRange.length - delta)
            var kept: [NSRange] = []
            var dropped: [NSRange] = []
            for fold in folds {
                if NSMaxRange(original) <= fold.location {
                    kept.append(NSRange(location: fold.location + delta, length: fold.length))
                } else if original.location > NSMaxRange(fold) {
                    kept.append(fold)
                } else {
                    dropped.append(NSRange(location: fold.location, length: max(0, fold.length + delta)))
                }
            }
            folds = kept
            if !dropped.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    for range in dropped { self?.refresh(range) }
                    self?.onFoldsChanged?()
                }
            }
        }
        super.processEditing(for: textStorage, edited: editMask, range: newCharRange, changeInLength: delta, invalidatedRange: invalidatedCharRange)
    }

    // MARK: Hiding

    func layoutManager(_ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?, atEnd layoutFinishedFlag: Bool) {
        onLayoutCompleted?()
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes charIndexes: UnsafePointer<Int>,
                       font aFont: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard !folds.isEmpty || !bookHidden.isEmpty || !bookReplacements.isEmpty else { return 0 }
        let count = glyphRange.length
        var changed = false
        var properties = [NSLayoutManager.GlyphProperty](repeating: [], count: count)
        for i in 0..<count {
            properties[i] = props[i]
            if bookReplacements[charIndexes[i]] != nil, !folds.contains(where: { NSLocationInRange(charIndexes[i], $0) }) {
                properties[i] = .controlCharacter
                changed = true
            } else if isHidden(charIndexes[i]) {
                properties[i] = .null
                changed = true
            }
        }
        guard changed else { return 0 }
        properties.withUnsafeBufferPointer { buffer in
            setGlyphs(glyphs, properties: buffer.baseAddress!, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
        }
        return count
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        if bookReplacements[charIndex] != nil, !folds.contains(where: { NSLocationInRange(charIndex, $0) }) { return .whitespace }
        if isHidden(charIndex) { return .zeroAdvancement }
        return bookJoins.contains(charIndex) ? .whitespace : action
    }

    /// A joined newline is as wide as a space of its font.
    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int, for textContainer: NSTextContainer,
                       proposedLineFragment proposedRect: NSRect, glyphPosition: NSPoint, characterIndex charIndex: Int) -> NSRect {
        if let replacement = bookReplacements[charIndex] {
            return NSRect(x: glyphPosition.x, y: 0, width: replacement.size.width, height: proposedRect.height)
        }
        let font = (textStorage?.attribute(.font, at: charIndex, effectiveRange: nil) as? NSFont) ?? .systemFont(ofSize: 13)
        let width = (" " as NSString).size(withAttributes: [.font: font]).width
        return NSRect(x: glyphPosition.x, y: 0, width: width, height: proposedRect.height)
    }

    private func isHidden(_ index: Int) -> Bool {
        // Folds are few; a linear scan is fine.
        bookHidden.contains(index) || folds.contains { NSLocationInRange(index, $0) }
    }

    // MARK: Book view replacements

    private func drawReplacements(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard !bookReplacements.isEmpty, let length = textStorage?.length else { return }
        let shown = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        for (index, replacement) in bookReplacements where NSLocationInRange(index, shown) && index < length {
            guard !folds.contains(where: { NSLocationInRange(index, $0) }) else { continue }
            let glyph = glyphIndexForCharacter(at: index)
            let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let used = lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            let location = self.location(forGlyphAt: glyph)
            let x = origin.x + fragment.minX + location.x
            if replacement.isMultiline {
                let y = origin.y + used.minY + (used.height - replacement.size.height) / 2
                replacement.text.draw(with: NSRect(x: x, y: y, width: replacement.size.width, height: replacement.size.height),
                                      options: [.usesLineFragmentOrigin, .usesFontLeading])
            } else {
                // Without .usesLineFragmentOrigin the point is the baseline, as for the text around it.
                replacement.text.draw(with: NSRect(x: x, y: origin.y + fragment.minY + location.y, width: replacement.size.width + 4, height: 0),
                                      options: [])
            }
        }
    }

    // MARK: Book view boxes

    /// Room for a figure's image: the line fragment with its opening fence is made taller and its
    /// text moved down. Hidden lines are laid out on a neighbouring line, so that fragment may
    /// start before the fence.
    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard !bookBoxes.isEmpty || !bookReplacements.isEmpty else { return false }
        let characters = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        // A replacement of several lines (aligned equations) makes its line taller.
        var changed = false
        for (index, replacement) in bookReplacements where replacement.isMultiline && NSLocationInRange(index, characters) {
            let extra = replacement.size.height + 6 - lineFragmentUsedRect.pointee.height
            if extra > 0 {
                lineFragmentRect.pointee.size.height += extra
                lineFragmentUsedRect.pointee.size.height += extra
                changed = true
            }
        }
        for box in bookBoxes where NSLocationInRange(box.range.location, characters) {
            guard case .figure(_, let size, _) = box.kind else { continue }
            let extra = size.height + 16
            lineFragmentRect.pointee.size.height += extra
            lineFragmentUsedRect.pointee.origin.y += extra
            baselineOffset.pointee += extra
            return true
        }
        return changed
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard !bookBoxes.isEmpty, let container = textContainers.first, let storage = textStorage else { return }
        let shown = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        for box in bookBoxes where NSIntersectionRange(box.range, shown).length > 0 || NSLocationInRange(box.range.location, shown) {
            guard NSMaxRange(box.range) <= storage.length else { continue }
            let glyphs = glyphRange(forCharacterRange: box.range, actualCharacterRange: nil)
            var rect = NSRect.null
            // Only lines that show some of the block: a hidden fence can run into a blank line next to it.
            enumerateLineFragments(forGlyphRange: glyphs) { [self] fragment, _, _, fragmentGlyphs, _ in
                let inBox = NSIntersectionRange(characterRange(forGlyphRange: fragmentGlyphs, actualGlyphRange: nil), box.range)
                let shows = (inBox.location..<NSMaxRange(inBox)).contains { !isHidden($0) }
                if shows || box.kind.isFigure { rect = rect.union(fragment) }
            }
            guard !rect.isNull else { continue }
            let inset = container.lineFragmentPadding + BookStyler.boxInset * CGFloat(box.depth)
            rect.origin.x = origin.x + inset
            rect.size.width = container.size.width - 2 * inset
            rect.origin.y += origin.y
            switch box.kind {
            case .callout(let color):
                let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6)
                color.withAlphaComponent(0.08).setFill()
                shape.fill()
                NSGraphicsContext.saveGraphicsState()
                shape.addClip()
                color.withAlphaComponent(0.85).setFill()
                NSRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height).fill()
                NSGraphicsContext.restoreGraphicsState()
            case .panel:
                // Drawing happens on the main thread.
                MainActor.assumeIsolated { MystHighlighter.codeBackground }.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: -4), xRadius: 6, yRadius: 6).fill()
            case .figure(let image, let size, let missing):
                // The image goes into the space reserved above the figure's first line.
                let firstGlyph = glyphIndexForCharacter(at: box.range.location)
                let line = lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: nil)
                let target = NSRect(x: rect.midX - size.width / 2, y: origin.y + line.minY + 8, width: size.width, height: size.height)
                if let image {
                    image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                } else {
                    let shape = NSBezierPath(roundedRect: target, xRadius: 6, yRadius: 6)
                    shape.setLineDash([4, 3], count: 2, phase: 0)
                    NSColor.tertiaryLabelColor.setStroke()
                    shape.stroke()
                    let label = "Image not found: \(missing ?? "")" as NSString
                    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
                    let labelSize = label.size(withAttributes: attributes)
                    label.draw(at: NSPoint(x: target.midX - labelSize.width / 2, y: target.midY - labelSize.height / 2), withAttributes: attributes)
                }
            }
        }
    }

    // MARK: Badge

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        drawReplacements(forGlyphRange: glyphsToShow, at: origin)
        guard !folds.isEmpty, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        for fold in folds where fold.location > 0 && NSLocationInRange(fold.location - 1, NSRange(location: characters.location, length: characters.length + 1)) {
            let glyph = glyphIndexForCharacter(at: fold.location - 1)
            let line = lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            let font = (textStorage?.attribute(.font, at: fold.location - 1, effectiveRange: nil) as? NSFont) ?? .systemFont(ofSize: 12)
            let label = " ⋯ " as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: font.pointSize * 0.85, weight: .semibold),
                                                             .foregroundColor: NSColor.secondaryLabelColor]
            let size = label.size(withAttributes: attributes)
            let rect = NSRect(x: origin.x + line.maxX + 6, y: origin.y + line.minY + (line.height - size.height) / 2 - 1,
                              width: size.width, height: size.height + 2)
            guard rect.maxX <= container.size.width + origin.x + 60 else { continue }
            NSColor.secondaryLabelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            label.draw(at: NSPoint(x: rect.minX, y: rect.minY + 1), withAttributes: attributes)
        }
    }
}
