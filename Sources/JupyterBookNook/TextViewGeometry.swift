import AppKit

/// Positions of lines in an NSTextView that are exact also for text outside the visible area.
/// The editor uses TextKit 1 with contiguous layout, where they are exact. For TextKit 2 views,
/// `firstRect(forCharacterRange:)` returns one placeholder rectangle for every location that is
/// not laid out yet, and layout fragment frames are estimates that shift after width changes.
extension NSTextView {
    /// The top of the line containing `location`, in the text view's coordinates.
    func lineTop(at location: Int) -> CGFloat {
        let length = (string as NSString).length
        let location = max(0, min(location, length))
        if let layoutManager = textLayoutManager, let contentManager = layoutManager.textContentManager {
            let start = contentManager.documentRange.location
            guard let target = contentManager.location(start, offsetBy: location) else { return 0 }
            if let range = NSTextRange(location: start, end: target) {
                layoutManager.ensureLayout(for: range)
            }
            let fragment = layoutManager.textLayoutFragment(for: target)
                ?? (location > 0 ? contentManager.location(target, offsetBy: -1).flatMap { layoutManager.textLayoutFragment(for: $0) } : nil)
            return (fragment?.layoutFragmentFrame.minY ?? 0) + textContainerOrigin.y
        }
        // TextKit 1 (only if the view was created with it; asking for `layoutManager` on a
        // TextKit 2 view would switch it to TextKit 1, so this is checked second).
        guard let layoutManager, length > 0 else { return textContainerOrigin.y }
        let character = min(location, length - 1)
        // The whole text, not just up to `location`: the text view's height (which limits how
        // far it can scroll) is only right once everything is laid out. Cheap once cached.
        if let textContainer { layoutManager.ensureLayout(for: textContainer) }
        let glyph = layoutManager.glyphIndexForCharacter(at: character)
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + textContainerOrigin.y
    }

    /// The character at the top of the visible area, `offset` points below its top edge.
    func characterIndexAtTop(offset: CGFloat) -> Int {
        let point = NSPoint(x: textContainerOrigin.x + 2, y: visibleRect.minY + offset)
        return characterIndexForInsertion(at: point)
    }

    /// Scrolls so that the line containing `location` is `margin` points below the top.
    func scrollLine(at location: Int, toTopWithMargin margin: CGFloat, animated: Bool) {
        guard let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        let target = location == 0 ? 0 : lineTop(at: location) - margin
        let maxY = max(0, frame.height - clip.bounds.height)
        let origin = NSPoint(x: clip.bounds.origin.x, y: max(0, min(target, maxY)))
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                clip.animator().setBoundsOrigin(origin)
            }
        } else {
            clip.setBoundsOrigin(origin)
        }
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Source lines (scroll sync)

    /// Where each line starts (UTF-16 offsets), for `sourceLine(atTopOffset:lineStarts:)`.
    static func lineStarts(of text: String) -> [Int] {
        var starts = [0]
        var index = 0
        for unit in text.utf16 {
            index += 1
            if unit == 10 { starts.append(index) }
        }
        return starts
    }

    /// The 0-based line that contains `location`, given the starts from `lineStarts(of:)`.
    nonisolated static func lineIndex(of location: Int, in lineStarts: [Int]) -> Int {
        var low = 0, high = max(0, lineStarts.count - 1)
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= location { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// The top and bottom of source line `index` (0-based), in the text view's coordinates.
    /// Folded and hidden lines have no height.
    private func lineSpan(_ index: Int, lineStarts: [Int]) -> (top: CGFloat, bottom: CGFloat) {
        let length = (string as NSString).length
        let top = lineTop(at: lineStarts[index])
        let bottom: CGFloat
        if index + 1 < lineStarts.count, lineStarts[index + 1] < length {
            bottom = lineTop(at: lineStarts[index + 1])
        } else {
            bottom = max(top, frame.height - textContainerOrigin.y)
        }
        return (top, max(top, bottom))
    }

    /// The source line at `offset` points below the top of the visible area: 1-based, with the
    /// fraction of that line above the probe (12.5: halfway through line 12).
    func sourceLine(atTopOffset offset: CGFloat, lineStarts: [Int]) -> Double {
        guard !lineStarts.isEmpty else { return 1 }
        let y = visibleRect.minY + offset
        let low = Self.lineIndex(of: characterIndexAtTop(offset: offset), in: lineStarts)
        let span = lineSpan(low, lineStarts: lineStarts)
        let fraction = span.bottom > span.top ? min(1, max(0, (y - span.top) / (span.bottom - span.top))) : 0
        return Double(low + 1) + Double(fraction)
    }

    /// How far the view is into its last screenful: 0 above it, rising to 1 at the bottom.
    var endWeight: Double {
        guard let clip = enclosingScrollView?.contentView else { return 0 }
        let maxY = frame.height - clip.bounds.height
        let zone = min(clip.bounds.height, maxY)
        guard zone > 0 else { return 0 }
        return Double(max(0, min(1, 1 - (maxY - clip.bounds.origin.y) / zone)))
    }

    /// Scrolls so that the place `line` (as from `sourceLine(atTopOffset:)`) is `offset` points
    /// below the top; `end` (0…1) moves the target that share of the way to the bottom, so the
    /// last line is reached together with the other side.
    func scrollToSourceLine(_ line: Double, offset: CGFloat, lineStarts: [Int], end: Double = 0) {
        guard let scrollView = enclosingScrollView, !lineStarts.isEmpty else { return }
        let index = min(lineStarts.count - 1, max(0, Int(line.rounded(.down)) - 1))
        let fraction = CGFloat(max(0, min(1, line - Double(index + 1))))
        let span = lineSpan(index, lineStarts: lineStarts)
        let clip = scrollView.contentView
        var target = span.top + fraction * (span.bottom - span.top) - offset
        let maxY = max(0, frame.height - clip.bounds.height)
        if end > 0, maxY > target { target += CGFloat(end) * (maxY - target) }
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: max(0, min(target, maxY))))
        scrollView.reflectScrolledClipView(clip)
    }
}
