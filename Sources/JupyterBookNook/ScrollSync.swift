import Foundation
import MystSyntax
import Observation

/// Keeps editor and preview on the same place in Split view. When the preview could match its
/// paragraphs to source lines (PreviewScripts.scrollSync), each side reports the source line at
/// its top, as a fraction, and the other follows paragraph by paragraph. Otherwise each side
/// reports the heading at its top and the other scrolls to the paired heading. Scrolling caused
/// by the sync itself is not reported back, so the two cannot chase each other.
/// Scroll-sync diagnostics on stderr, only when the app is started with NOOK_DEBUG_SYNC=1.
private let syncLogging = ProcessInfo.processInfo.environment["NOOK_DEBUG_SYNC"] == "1"

func syncLog(_ message: @autoclosure () -> String) {
    guard syncLogging else { return }
    FileHandle.standardError.write(Data("[sync] \(message())\n".utf8))
}

@MainActor
@Observable
final class ScrollSync {
    var isEnabled = UserDefaults.standard.object(forKey: "scrollSync") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "scrollSync")
            syncLog("sync \(isEnabled ? "on" : "off")")
            // Turned back on: bring the preview to the editor's section now, not only at the next
            // heading, so it is visibly working again.
            if isEnabled && !oldValue { alignPreviewToEditor(animated: true) }
        }
    }

    /// Installed by the preview web view: scroll to a source line (1-based, fractional), or to a
    /// preview heading (-1: top) when the line is nil or the page has no line anchors.
    /// `end` (0…1) is how far the editor is into its last screenful; the preview moves that share
    /// of the way to its own end, so the two reach their last lines together.
    @ObservationIgnored var scrollPreview: ((_ line: Double?, _ heading: Int, _ animated: Bool, _ end: Double) -> Void)?
    /// Installed by the current editor: put a source range at the top.
    @ObservationIgnored var scrollEditor: ((_ range: NSRange) -> Void)?
    /// Installed by the current editor: put a source line (1-based, fractional) at the top.
    /// `end` as for `scrollPreview`, from the preview.
    @ObservationIgnored var scrollEditorToLine: ((_ line: Double, _ end: Double) -> Void)?
    /// Installed by the current editor: the heading at its top right now.
    @ObservationIgnored var editorTopHeading: (() -> Int?)?
    /// Installed by the current editor: the source line at its top right now.
    @ObservationIgnored var editorTopLine: (() -> (line: Double, end: Double)?)?

    /// A selection's place on the other side: source lines (1-based) and its text as a reader
    /// sees it. Nil clears the highlight.
    struct Selection: Equatable {
        var start: Int
        var end: Int
        var text: String
    }
    /// Installed by the preview web view: mark the editor's selection in the page.
    @ObservationIgnored var highlightPreview: ((Selection?) -> Void)?
    /// Installed by the current editor: mark the preview's selection in the source.
    @ObservationIgnored var highlightEditor: ((Selection?) -> Void)?
    /// The last selection sent to the preview, so moving the cursor does not resend "nothing".
    @ObservationIgnored private var lastEditorSelection: Selection?

    /// Whether the preview page matched its paragraphs to source lines; then the sync works by line.
    @ObservationIgnored private(set) var previewHasLines = false
    @ObservationIgnored private var editorLine: Double?
    @ObservationIgnored private var editorEnd = 0.0

    @ObservationIgnored private var previewHeadings: [PreviewHeading] = []
    @ObservationIgnored private var editorHeadingIndex: Int?
    @ObservationIgnored private var editorDrivenUntil = Date.distantPast
    @ObservationIgnored private var previewDrivenUntil = Date.distantPast

    /// Asked for the page in the editor and whether syncing applies (Split view).
    @ObservationIgnored var context: () -> (headings: [MystHeading], active: Bool) = { ([], false) }

    private var alignment: [Int?] {
        HeadingAnchors.align(context().headings, with: previewHeadings)
    }

    /// The editor scrolled: the source line and the heading now at its top.
    func editorScrolled(toLine line: Double?, end: Double = 0, heading: Int?) {
        guard previewHasLines, let line else {
            editorScrolled(toHeading: heading)
            return
        }
        editorHeadingIndex = heading
        // Small moves within a line are not worth a round trip (near the end, the share does change).
        if let last = editorLine, abs(last - line) < 0.2, abs(editorEnd - end) < 0.02 { return }
        editorLine = line
        editorEnd = end
        guard isEnabled, context().active, Date() > previewDrivenUntil else { return }
        editorDrivenUntil = Date().addingTimeInterval(0.35)
        scrollPreview?(line, heading.flatMap { HeadingAnchors.previewIndex(forSource: $0, alignment: alignment) } ?? -1, false, end)
    }

    /// The editor's top section changed (nil: above the first heading).
    func editorScrolled(toHeading index: Int?) {
        guard index != editorHeadingIndex else { return }
        editorHeadingIndex = index
        let context = context()
        let suppressed = Date() <= previewDrivenUntil
        syncLog("editor top heading -> \(index.map(String.init) ?? "none") \(index.map { context.headings.indices.contains($0) ? "“" + context.headings[$0].title + "”" : "?" } ?? "")\(suppressed ? " (caused by sync, not forwarded)" : "")")
        guard isEnabled, context.active, Date() > previewDrivenUntil else { return }
        editorDrivenUntil = Date().addingTimeInterval(0.9)
        let target = index.flatMap { HeadingAnchors.previewIndex(forSource: $0, alignment: alignment) } ?? -1
        syncLog("  -> preview scrolls to \(target) \(previewHeadings.indices.contains(target) ? previewHeadings[target].id : "")")
        scrollPreview?(nil, target, true, 0)
    }

    /// The preview scrolled: its top heading (-1: above the first) and source line (nil when the
    /// page has no line anchors).
    func previewScrolled(toHeading index: Int, line: Double?, end: Double = 0) {
        guard previewHasLines, let line else {
            previewScrolled(toHeading: index)
            return
        }
        guard isEnabled, context().active, Date() > editorDrivenUntil else { return }
        previewDrivenUntil = Date().addingTimeInterval(0.35)
        editorLine = line
        editorEnd = end
        scrollEditorToLine?(line, end)
    }

    /// Text was selected in the editor (nil: nothing selected): the preview marks it.
    func editorSelectionChanged(_ selection: Selection?) {
        guard isEnabled, context().active, previewHasLines, selection != lastEditorSelection else { return }
        lastEditorSelection = selection
        syncLog("editor selection -> preview: \(selection.map { "lines \($0.start)–\($0.end) “\($0.text.prefix(40))”" } ?? "cleared")")
        highlightPreview?(selection)
    }

    /// Text was selected in the preview (nil: nothing selected): the editor marks it.
    func previewSelectionChanged(_ selection: Selection?) {
        guard isEnabled, context().active else { return }
        syncLog("preview selection -> editor: \(selection.map { "lines \($0.start)–\($0.end) “\($0.text.prefix(40))”" } ?? "cleared")")
        highlightEditor?(selection)
    }

    /// The preview matched (or could not match) its paragraphs to source lines.
    func previewAnchorsChanged(count: Int, blocks: Int) {
        let hadLines = previewHasLines
        previewHasLines = count >= 2
        syncLog("preview line anchors: \(count) of \(blocks) blocks matched -> sync by \(previewHasLines ? "line" : "heading")")
        // Now able to follow by line: catch up with the editor.
        if previewHasLines && !hadLines { alignPreviewToEditor(animated: false) }
    }

    /// The preview's top section changed (-1: above the first heading).
    func previewScrolled(toHeading index: Int) {
        let context = context()
        syncLog("preview top heading -> \(index) \(previewHeadings.indices.contains(index) ? previewHeadings[index].id : "")\(Date() <= editorDrivenUntil ? " (caused by sync, ignored)" : "")\(context.active ? "" : " (not in Split)")")
        guard isEnabled, context.active, Date() > editorDrivenUntil else { return }
        previewDrivenUntil = Date().addingTimeInterval(0.9)
        let source = index < 0 ? nil : HeadingAnchors.sourceIndex(forPreview: index, alignment: alignment)
        editorHeadingIndex = source
        let range = source.map { context.headings[$0].range } ?? NSRange(location: 0, length: 0)
        syncLog("  -> editor heading \(source.map(String.init) ?? "none") \(source.map { "“" + context.headings[$0].title + "”" } ?? "") at character \(range.location)\(scrollEditor == nil ? " (NO EDITOR ATTACHED)" : "")")
        scrollEditor?(range)
    }

    /// The preview page's headings are known or changed. On a newly loaded page, jump to the
    /// section the editor shows, so switching tabs lands in the right place.
    func previewHeadingsChanged(_ headings: [PreviewHeading], initial: Bool) {
        previewHeadings = headings
        // A (re)loaded page matches its lines again and says so in an "anchors" message.
        if initial { previewHasLines = false }
        let page = context().headings
        syncLog("preview headings (\(initial ? "page loaded" : "changed")): \(headings.map(\.id))")
        syncLog("editor headings: \(page.map(\.title)) anchors \(HeadingAnchors.anchors(for: page))")
        syncLog("alignment editor->preview: \(HeadingAnchors.align(page, with: headings).map { $0.map(String.init) ?? "-" })")
        guard initial, isEnabled, context().active, let index = editorHeadingIndex else { return }
        if let target = HeadingAnchors.previewIndex(forSource: index, alignment: alignment) {
            scrollPreview?(nil, target, false, 0)
        }
    }

    /// Scrolls the preview to the section the editor shows (the top when above the first heading).
    func alignPreviewToEditor(animated: Bool) {
        guard isEnabled, context().active else { return }
        editorDrivenUntil = Date().addingTimeInterval(animated ? 0.9 : 0.3)
        if let current = editorTopHeading { editorHeadingIndex = current() }
        let top = previewHasLines ? editorTopLine?() : nil
        editorLine = top?.line
        editorEnd = top?.end ?? 0
        let target = editorHeadingIndex.flatMap { HeadingAnchors.previewIndex(forSource: $0, alignment: alignment) } ?? -1
        syncLog("align preview to editor line \(top.map { String(format: "%.1f (end %.2f)", $0.line, $0.end) } ?? "-"), heading \(editorHeadingIndex.map(String.init) ?? "none") -> preview \(target)")
        scrollPreview?(top?.line, target, animated, top?.end ?? 0)
    }

    /// A different page is in the editor.
    func pageChanged() {
        editorHeadingIndex = nil
        editorLine = nil
        previewHeadings = []
        previewHasLines = false
        lastEditorSelection = nil
    }
}
