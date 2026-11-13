import AppKit
import MystSyntax
import ProjectIndex
import SwiftUI

struct EditorArea: View {
    @Environment(BookStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            if !store.documents.isEmpty, !store.isFocusMode {
                TabBar()
                Divider()
            }
            if let document = store.currentDocument {
                if !store.isFocusMode {
                    BreadcrumbBar(document: document)
                    Divider()
                }
                if let conflict = document.diskConflict {
                    DiskConflictBar(document: document, conflict: conflict)
                    Divider()
                }
                if document.isViewOnly {
                    ViewOnlyPlaceholder(document: document)
                } else {
                MystTextEditor(document: document, scrollSync: store.scrollSync, focusMode: store.isFocusMode,
                               bookView: document.isBookView && document.isPage,
                               resolveReference: { [weak store] role, target in store?.referenceText(role: role, target: target, page: document.path) },
                               onCreate: { [weak store] textView in
                    store?.editorTextView = textView
                    // Images become figures, pages from the sidebar become links.
                    (textView as? MystTextView)?.dropProvider = { [weak store, weak textView] items, plain in
                        store?.editorDrop(items, plain: plain, page: document.path, undoManager: textView?.undoManager)
                    }
                    (textView as? MystTextView)?.onTableBadge = { [weak store] location in store?.showTableAssistant(at: location) }
                }) { [weak store] context, after in
                    store?.completions(for: context, page: document.path, textAfterCursor: after) ?? []
                }
                    .id(document.path)
                }
            } else {
                ContentUnavailableView(
                    "No page open",
                    systemImage: "doc.text",
                    description: Text("Choose a page in the sidebar, or create one with ⇧⌘N.")
                )
            }
        }
    }
}

/// The editor of a PDF, image or other file that is not text: the preview shows it.
struct ViewOnlyPlaceholder: View {
    @Environment(BookStore.self) private var store
    let document: OpenDocument

    var body: some View {
        ContentUnavailableView {
            Label("Not for editing", systemImage: "eye")
        } description: {
            Text("\(document.fileName) is not a text file. It is shown in the preview.")
        } actions: {
            HStack {
                if store.viewMode == .editor {
                    Button("Show Preview") { store.viewMode = .split }
                }
                Button("Open with Default App") { NSWorkspace.shared.open(document.url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([document.url]) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shown when a tab's file changed or disappeared on disk while the tab had unsaved edits.
struct DiskConflictBar: View {
    @Environment(BookStore.self) private var store
    let document: OpenDocument
    let conflict: OpenDocument.DiskConflict

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(conflict == .changed
                 ? "\(document.fileName) was changed in another app. Your edits here are not saved yet."
                 : "\(document.fileName) was deleted or moved in another app. Your edits here are not saved yet.")
                .lineLimit(2)
            Spacer()
            if conflict == .changed {
                Button("Use Version on Disk") { document.useDiskVersion() }
            } else {
                Button("Close Tab") {
                    document.useDiskVersion()
                    document.diskConflict = nil
                    store.discard(document)
                }
            }
            Button(conflict == .changed ? "Keep My Version" : "Save Again") { store.keepMine(document) }
                .buttonStyle(.borderedProminent)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.12))
    }
}

/// "intro.md › Background" on the left, the cursor position on the right.
struct BreadcrumbBar: View {
    let document: OpenDocument

    var body: some View {
        let index = MystOutline.headingIndex(at: document.selection.location, in: document.headings)
        let position = document.cursorPosition
        HStack(spacing: 4) {
            Text(document.path)
            if let index {
                Image(systemName: "chevron.compact.right")
                    .foregroundStyle(.tertiary)
                Text(document.headings[index].title)
            }
            Spacer()
            Text("Ln \(position.line), Col \(position.column)")
                .monospacedDigit()
            if document.isPage {
                Picker("View", selection: Binding(get: { document.isBookView }, set: { document.isBookView = $0 })) {
                    Text("Source").tag(false)
                    Text("Book").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .fixedSize()
                .help("Source shows the MyST text; Book shows the page as it looks in the book, with the markup of the paragraph you edit (⌥⌘B)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}

/// Tabs in a plain row that shrink when many are open.
/// Not in a ScrollView: SwiftUI stretches a horizontal ScrollView up under the window toolbar,
/// and the stretched scroll view then took every click meant for the tabs.
struct TabBar: View {
    @Environment(BookStore.self) private var store

    var body: some View {
        HStack(spacing: 2) {
            ForEach(store.documents) { document in
                TabButton(
                    document: document,
                    isSelected: document.path == store.currentPath,
                    select: { store.currentPath = document.path },
                    close: { store.close(document.path) }
                )
                .frame(minWidth: 60, maxWidth: 220)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.bar)
    }
}

struct TabButton: View {
    let document: OpenDocument
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(document.fileName)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: close) {
                // A dot marks unsaved changes; it turns into a close button on hover, as in Xcode.
                Image(systemName: document.isDirty && !isHovering ? "circle.fill" : "xmark")
                    .font(.system(size: document.isDirty && !isHovering ? 6 : 9, weight: .semibold))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Close \(document.fileName)")
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                .shadow(color: .black.opacity(isSelected ? 0.12 : 0), radius: 1, y: 0.5)
        )
        .foregroundStyle(isSelected ? .primary : .secondary)
        // The whole tab selects, not only its text; the close button keeps its own click.
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
        .help(document.path)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Select", select)
    }
}

/// MyST source editor built on NSTextView: highlighting, spell checking limited to prose,
/// find bar and undo.
struct MystTextEditor: NSViewRepresentable {
    let document: OpenDocument
    let scrollSync: ScrollSync
    /// Focus mode: lines limited to a readable width and, if set, other paragraphs dimmed.
    var focusMode = false
    /// The book view: styled like the book, markup hidden outside the cursor's paragraph.
    var bookView = false
    /// The text a reference is shown with in the book view.
    var resolveReference: ((String, String) -> String?)?
    /// Receives the text view once it exists (the store uses it for Find).
    let onCreate: (NSTextView) -> Void
    let completions: (CompletionContext, String) -> [CompletionItem]

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = Self.makeTextKit1ScrollView()
        guard let textView = scrollView.documentView as? MystTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.completionProvider = completions
        onCreate(textView)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        // Spell check prose, but never "correct" Markdown: no smart quotes, dashes or replacements.
        // Not in myst.yml: keys and paths are not words.
        textView.isContinuousSpellCheckingEnabled = context.coordinator.isPage
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        // No inline predictions: macOS 14+ shows suggested text (here: repeated fences and whole
        // blocks) after the cursor, which appeared after Backspace and vanished after Return,
        // and could end up in the page. Completion comes from the app's own list instead.
        textView.inlinePredictionType = .no
        textView.isAutomaticTextCompletionEnabled = false

        textView.textContainerInset = NSSize(width: 18, height: 14)
        textView.font = MystHighlighter.baseFont
        textView.typingAttributes = MystHighlighter.baseAttributes
        // Setting the text moves the cursor and reports that as a selection change; keep the
        // page's last selection to restore it below.
        let selection = document.selection
        textView.string = document.text
        document.selection = selection
        context.coordinator.appliedDiskRevision = document.diskRevision
        context.coordinator.focusMode = focusMode
        context.coordinator.bookView = bookView
        context.coordinator.resolveReference = resolveReference
        scrollView.verticalRulerView = LineNumberRuler(textView: textView, scrollView: scrollView)
        scrollView.hasVerticalRuler = true
        context.coordinator.observeSettings(textView: textView, scrollView: scrollView)
        context.coordinator.highlight(textView)
        textView.setSelectedRange(clamped(document.selection, in: textView))
        DispatchQueue.main.async { textView.scrollRangeToVisible(textView.selectedRange()) }
        context.coordinator.attachScrollSync(scrollSync, to: scrollView)
        return scrollView
    }

    /// A text view on TextKit 1 with contiguous layout. TextKit 2 (what
    /// `NSTextView.scrollableTextView()` creates) lays text out lazily and estimates the
    /// position of everything outside the visible area; with larger heading fonts and after
    /// width changes those estimates were off by whole sections, which broke scroll sync.
    /// TextKit 1 positions are exact; a keystroke on a 47 KB page, including re-highlighting
    /// and relayout, measured 9 ms (189 KB: 32 ms).
    static func makeTextKit1ScrollView() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        let storage = NSTextStorage()
        let layoutManager = FoldingLayoutManager()
        layoutManager.allowsNonContiguousLayout = false
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        let textView = MystTextView(frame: .zero, textContainer: container)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.document = document
        context.coordinator.resolveReference = resolveReference
        guard let textView = scrollView.documentView as? MystTextView else { return }
        textView.completionProvider = completions
        if context.coordinator.focusMode != focusMode || context.coordinator.bookView != bookView {
            context.coordinator.focusMode = focusMode
            context.coordinator.bookView = bookView
            context.coordinator.applySettings()
            textView.scrollRangeToVisible(textView.selectedRange())
        }
        context.coordinator.showDiagnostics(document.diagnostics, in: textView)
        // The editor's text is the truth while typing; it is replaced only when the page changed
        // on disk (e.g. a link rewritten by a rename), never just because the two differ.
        if document.diskRevision != context.coordinator.appliedDiskRevision {
            context.coordinator.appliedDiskRevision = document.diskRevision
            // Old typing-undo steps refer to the previous text, so drop them before replacing it.
            if let undoManager = textView.undoManager {
                undoManager.removeAllActions(withTarget: textView)
                if let storage = textView.textStorage { undoManager.removeAllActions(withTarget: storage) }
            }
            textView.string = document.text
            context.coordinator.textRevision += 1
            context.coordinator.highlight(textView)
            context.coordinator.applyYAMLFolds(force: true)
        }
        if let request = document.revealRequest, request.id != context.coordinator.handledReveal {
            context.coordinator.handledReveal = request.id
            let range = clamped(request.range, in: textView)
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
            textView.scrollRangeToVisible(range)
            textView.showFindIndicator(for: range)
        }
    }

    private func clamped(_ range: NSRange, in textView: NSTextView) -> NSRange {
        let length = (textView.string as NSString).length
        let location = min(range.location, length)
        return NSRange(location: location, length: min(range.length, length - location))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var document: OpenDocument
        var handledReveal: UUID?
        /// The document's disk revision the text view shows.
        var appliedDiskRevision = 0
        private weak var scrollView: NSScrollView?
        private weak var scrollSync: ScrollSync?
        private var boundsObserver: NSObjectProtocol?
        private var frameObserver: NSObjectProtocol?

        /// Reports the section at the top of the editor as it scrolls, and lets the sync put a
        /// heading at the top.
        func attachScrollSync(_ sync: ScrollSync, to scrollView: NSScrollView) {
            self.scrollView = scrollView
            scrollSync = sync
            scrollView.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
            ) { [weak self, weak scrollView] _ in
                MainActor.assumeIsolated {
                    self?.reportTopHeading()
                    // Keep the completion list next to its text while scrolling.
                    if let textView = scrollView?.documentView as? MystTextView, textView.completionPopup.isShown {
                        textView.updateCompletion(open: false)
                    }
                }
            }
            sync.scrollEditor = { [weak self] range in self?.scrollToTop(range) }
            sync.scrollEditorToLine = { [weak self] line, end in self?.scrollToLine(line, end: end) }
            sync.editorTopHeading = { [weak self] in self?.topHeadingIndex() }
            sync.editorTopLine = { [weak self] in self?.topLine() }
            sync.highlightEditor = { [weak self] selection in self?.markPreviewSelection(selection) }
            // The text view is at least as tall as the visible area, so clicking below the
            // last line of a short page still puts the cursor there.
            scrollView.contentView.postsFrameChangedNotifications = true
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: scrollView.contentView, queue: .main
            ) { [weak scrollView] _ in
                MainActor.assumeIsolated {
                    guard let scrollView, let textView = scrollView.documentView as? NSTextView else { return }
                    textView.minSize = NSSize(width: 0, height: scrollView.contentView.bounds.height)
                    textView.sizeToFit()
                    (textView.delegate as? Coordinator)?.updateInsets()
                }
            }
        }

        deinit {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        }

        /// Where the sync puts a heading: this far below the top edge…
        static let headingMargin: CGFloat = 4
        /// …and where the top section is read: inside that heading's line, so a heading the
        /// sync just scrolled to counts as the top section.
        static let topProbe: CGFloat = 10

        private func topHeadingIndex() -> Int? {
            guard let scrollView, let textView = scrollView.documentView as? NSTextView else { return nil }
            let location = textView.characterIndexAtTop(offset: Self.topProbe)
            return MystOutline.headingIndex(at: location, in: document.headings)
        }

        private func reportTopHeading() {
            let top = topLine()
            scrollSync?.editorScrolled(toLine: top?.line, end: top?.end ?? 0, heading: topHeadingIndex())
        }

        /// Line starts of the text, for the line-based sync; rebuilt after the text changes.
        private var cachedLineStarts: (length: Int, revision: Int, starts: [Int])?
        var textRevision = 0

        private func lineStarts(_ textView: NSTextView) -> [Int] {
            let length = (textView.string as NSString).length
            if let cached = cachedLineStarts, cached.length == length, cached.revision == textRevision { return cached.starts }
            let starts = NSTextView.lineStarts(of: textView.string)
            cachedLineStarts = (length, textRevision, starts)
            return starts
        }

        /// The source line at the top, read where a synced line is put (`headingMargin`).
        private func topLine() -> (line: Double, end: Double)? {
            guard let scrollView, let textView = scrollView.documentView as? NSTextView else { return nil }
            return (textView.sourceLine(atTopOffset: Self.headingMargin, lineStarts: lineStarts(textView)), textView.endWeight)
        }

        // MARK: Selection highlighting

        /// Where the preview's selection is marked in the text (a temporary attribute, never saved).
        private var highlighted: NSRange?
        private var selectionReport: DispatchWorkItem?
        static let highlightColor = NSColor.systemYellow.withAlphaComponent(0.45)

        /// Marks the preview's selection: its text in the source lines it spans, or those lines.
        func markPreviewSelection(_ selection: ScrollSync.Selection?) {
            guard let scrollView, let textView = scrollView.documentView as? NSTextView, let layoutManager = textView.layoutManager else { return }
            if let old = highlighted, NSMaxRange(old) <= (textView.string as NSString).length {
                layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: old)
            }
            highlighted = nil
            guard let selection,
                  let range = PlainProjection.sourceRange(of: selection.text, lines: selection.start...max(selection.start, selection.end), in: textView.string)
            else { return }
            layoutManager.addTemporaryAttribute(.backgroundColor, value: Self.highlightColor, forCharacterRange: range)
            highlighted = range
        }

        /// The editor's selection, shortly after it stops changing: the preview marks it.
        func reportSelection(_ textView: NSTextView) {
            selectionReport?.cancel()
            let work = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                let range = textView.selectedRange()
                guard range.length > 0 else {
                    self.scrollSync?.editorSelectionChanged(nil)
                    return
                }
                let starts = self.lineStarts(textView)
                func line(_ location: Int) -> Int { NSTextView.lineIndex(of: location, in: starts) + 1 }
                let text = PlainProjection((textView.string as NSString).substring(with: range)).text
                self.scrollSync?.editorSelectionChanged(.init(start: line(range.location), end: line(NSMaxRange(range) - 1), text: String(text.prefix(2000))))
            }
            selectionReport = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        private func scrollToLine(_ line: Double, end: Double) {
            guard let scrollView, let textView = scrollView.documentView as? NSTextView else { return }
            textView.scrollToSourceLine(line, offset: Self.headingMargin, lineStarts: lineStarts(textView), end: end)
        }

        private func scrollToTop(_ range: NSRange) {
            guard let scrollView, let textView = scrollView.documentView as? NSTextView else { return }
            let before = scrollView.contentView.bounds.origin.y
            let lineTop = textView.lineTop(at: range.location)
            textView.scrollLine(at: range.location, toTopWithMargin: Self.headingMargin, animated: true)
            syncLog("  editor scroll: line top \(Int(lineTop)), clip y \(Int(before)) -> \(Int(scrollView.contentView.bounds.origin.y)) (target \(Int(lineTop - Self.headingMargin))), text height \(Int(textView.frame.height)), visible \(Int(scrollView.contentView.bounds.height))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak textView, weak scrollView] in
                guard let self, let textView, let scrollView else { return }
                let top = textView.characterIndexAtTop(offset: Self.topProbe)
                syncLog("  editor after 0.5 s: clip y \(Int(scrollView.contentView.bounds.origin.y)), top heading \(MystOutline.headingIndex(at: top, in: self.document.headings).map(String.init) ?? "none")")
            }
        }

        var focusMode = false
        var bookView = false
        var resolveReference: ((String, String) -> String?)?
        /// What the book view may hide, from the last styling, and the paragraphs shown with markup.
        private var presentation = BookStyler.Presentation()
        private var revealed: NSRange?
        private weak var styledTextView: NSTextView?
        private var settingsObserver: NSObjectProtocol?

        /// Restyles the editor when Settings › Editor changes.
        func observeSettings(textView: NSTextView, scrollView: NSScrollView) {
            styledTextView = textView
            self.scrollView = scrollView
            settingsObserver = NotificationCenter.default.addObserver(forName: EditorSettings.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applySettings() }
            }
            applySettings()
        }

        /// Font, colours, line numbers, line width and dimming from the settings and focus mode.
        func applySettings() {
            guard let textView = styledTextView, let scrollView else { return }
            let settings = EditorSettings.shared
            textView.font = bookView ? BookStyler.bodyFont : MystHighlighter.baseFont
            highlight(textView)
            scrollView.rulersVisible = (settings.showsLineNumbers || settings.showsFoldMarkers) && !focusMode && !bookView
            (scrollView.verticalRulerView as? LineNumberRuler)?.textChanged()
            updateInsets()
            updateDimming()
            applyYAMLFolds()
        }

        /// The (front matter, options) hiding last applied; folds change only when these do, so a
        /// fold opened by hand stays open when other settings change.
        var appliedYAMLFolds: (Bool, Bool)?

        /// Hides front matter and directive options in the source view, as Settings › Editor says.
        func applyYAMLFolds(force: Bool = false) {
            guard let textView = styledTextView as? MystTextView else { return }
            let settings = EditorSettings.shared
            let wanted = (settings.hidesFrontMatter && !bookView, settings.hidesDirectiveOptions && !bookView)
            if !force, let applied = appliedYAMLFolds, applied == wanted { return }
            appliedYAMLFolds = wanted
            textView.applyYAMLFolds(frontMatter: wanted.0, options: wanted.1)
        }

        /// Centres the text in a column of `readableColumns` characters when the width is limited
        /// (always in focus mode); otherwise a small margin.
        func updateInsets() {
            guard let textView = styledTextView, let scrollView else { return }
            let settings = EditorSettings.shared
            var horizontal: CGFloat = 18
            let padding = 2 * (textView.textContainer?.lineFragmentPadding ?? 5)
            if bookView {
                // A page: a readable column with generous margins.
                horizontal = max(28, (scrollView.contentView.bounds.width - BookStyler.columnWidth - padding) / 2)
            } else if settings.limitsLineWidth || focusMode {
                let column = settings.characterWidth * CGFloat(settings.readableColumns) + padding
                horizontal = max(18, (scrollView.contentView.bounds.width - column) / 2)
            }
            let inset = NSSize(width: horizontal.rounded(), height: focusMode || bookView ? 40 : 14)
            if textView.textContainerInset != inset { textView.textContainerInset = inset }
        }

        /// In focus mode, dims everything but the paragraph with the cursor (temporary attributes,
        /// so the file and the highlighting are untouched).
        func updateDimming() {
            guard let textView = styledTextView, let layoutManager = textView.layoutManager else { return }
            let text = textView.string as NSString
            let full = NSRange(location: 0, length: text.length)
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
            guard focusMode, EditorSettings.shared.dimsInFocusMode, text.length > 0 else { return }
            let paragraph = Self.paragraphRange(at: textView.selectedRange().location, in: text)
            let dim = NSColor.tertiaryLabelColor
            if paragraph.location > 0 {
                layoutManager.addTemporaryAttribute(.foregroundColor, value: dim, forCharacterRange: NSRange(location: 0, length: paragraph.location))
            }
            if NSMaxRange(paragraph) < text.length {
                layoutManager.addTemporaryAttribute(.foregroundColor, value: dim, forCharacterRange: NSRange(location: NSMaxRange(paragraph), length: text.length - NSMaxRange(paragraph)))
            }
        }

        /// The block of non-empty lines around `location` (a paragraph, list or directive body).
        static func paragraphRange(at location: Int, in text: NSString) -> NSRange {
            func isBlank(_ line: NSRange) -> Bool {
                text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let here = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
            if isBlank(here) { return here }
            var start = here.location
            while start > 0 {
                let previous = text.lineRange(for: NSRange(location: start - 1, length: 0))
                if isBlank(previous) { break }
                start = previous.location
            }
            var end = NSMaxRange(here)
            while end < text.length {
                let next = text.lineRange(for: NSRange(location: end, length: 0))
                if isBlank(next) { break }
                end = NSMaxRange(next)
            }
            return NSRange(location: start, length: end - start)
        }

        /// Sorted ranges of code, math, roles and other syntax that spell checking skips.
        private var spellExcluded = SpellingExclusions()

        init(document: OpenDocument) {
            self.document = document
        }

        /// Pages are MyST; myst.yml is YAML, plugins JavaScript, other files plain text.
        var isPage: Bool { document.isPage }

        func highlight(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            defer {
                (scrollView?.verticalRulerView as? LineNumberRuler)?.textChanged()
                if focusMode { updateDimming() }
            }
            guard isPage else {
                switch (document.path as NSString).pathExtension.lowercased() {
                case "yml", "yaml": MystHighlighter.highlightYAML(storage)
                case "js", "mjs", "cjs", "ts": MystHighlighter.highlightJavaScript(storage)
                default: MystHighlighter.highlightPlain(storage)
                }
                (textView as? MystTextView)?.noCompletionRanges = [NSRange(location: 0, length: storage.length)]
                if !document.headings.isEmpty { document.headings = [] }
                textView.typingAttributes = MystHighlighter.baseAttributes
                return
            }
            let tokens: [MystToken]
            if bookView {
                tokens = MystTokenizer.tokens(in: storage.string)
                presentation = BookStyler.style(storage, tokens: tokens, pageURL: document.url, resolve: resolveReference)
                (textView.layoutManager as? FoldingLayoutManager)?.bookBoxes = presentation.boxes
                updateReveal(textView, force: true)
            } else {
                tokens = MystHighlighter.highlight(storage)
                if !presentation.hideable.isEmpty || !presentation.joins.isEmpty || !presentation.boxes.isEmpty {
                    presentation = BookStyler.Presentation()
                    revealed = nil
                    (textView.layoutManager as? FoldingLayoutManager)?.setBookPresentation(hidden: IndexSet(), joins: IndexSet())
                    (textView.layoutManager as? FoldingLayoutManager)?.bookBoxes = []
                }
            }
            spellExcluded = SpellingExclusions(tokens: tokens)
            // Not the fence line itself: while "```{" is typed, the line is still a plain code fence.
            (textView as? MystTextView)?.noCompletionRanges = tokens.compactMap { token in
                switch token.kind {
                case .code, .inlineCode, .math, .mathDelimiter, .frontMatter, .comment: return token.range
                default: return nil
                }
            }
            // Highlighting resets the text's attributes; the underlines are temporary attributes and stay.
            shownDiagnostics = nil
            showDiagnostics(document.diagnostics, in: textView)
            let headings = MystOutline.headings(in: storage.string, tokens: tokens)
            if headings != document.headings { document.headings = headings }
            (textView as? MystTextView)?.tableStarts = MystTables.all(in: storage.string).map(\.range.location)
            textView.typingAttributes = bookView ? BookStyler.bodyAttributes : MystHighlighter.baseAttributes
        }

        /// In the book view, shows the markup of the paragraphs the selection touches and hides it
        /// everywhere else.
        func updateReveal(_ textView: NSTextView, force: Bool = false) {
            guard bookView, let manager = textView.layoutManager as? FoldingLayoutManager else { return }
            let range = BookStyler.revealedRange(for: textView.selectedRange(), in: textView.string as NSString)
            guard force || range != revealed else { return }
            revealed = range
            let shown = presentation.hidden(revealed: range)
            manager.setBookPresentation(hidden: shown.hidden, joins: shown.joins, replacements: shown.replacements)
        }

        private var shownDiagnostics: [Diagnostic]?

        /// Dotted underlines for the page's problems, orange for warnings and red for errors,
        /// with the message as a tooltip. Temporary attributes, so they never reach the file.
        func showDiagnostics(_ diagnostics: [Diagnostic], in textView: NSTextView) {
            guard diagnostics != shownDiagnostics, let layoutManager = textView.layoutManager else { return }
            shownDiagnostics = diagnostics
            let length = (textView.string as NSString).length
            let full = NSRange(location: 0, length: length)
            for key in [NSAttributedString.Key.underlineStyle, .underlineColor, .toolTip] {
                layoutManager.removeTemporaryAttribute(key, forCharacterRange: full)
            }
            for diagnostic in diagnostics where diagnostic.range.length > 0 && NSMaxRange(diagnostic.range) <= length {
                layoutManager.addTemporaryAttributes([
                    .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
                    .underlineColor: diagnostic.severity == .error ? NSColor.systemRed : NSColor.systemOrange,
                    .toolTip: diagnostic.message,
                ], forCharacterRange: diagnostic.range)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            textRevision += 1
            document.text = textView.string
            document.onEdit?()
            // Re-colouring while a dead key or input method is composing would disturb it;
            // the next change after composing finishes highlights again.
            if !textView.hasMarkedText() { highlight(textView) }

        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            if range != document.selection { document.selection = range }
            // Selecting here replaces a highlight from the preview, and is marked there instead.
            if highlighted != nil { markPreviewSelection(nil) }
            reportSelection(textView)
            // A cursor (from a click, Find or the outline) that lands in folded text opens that fold.
            if let manager = textView.layoutManager as? FoldingLayoutManager {
                let hidden = manager.folds.filter { range.location > $0.location && range.location <= NSMaxRange($0) }
                if !hidden.isEmpty { manager.setFolds(manager.folds.filter { !hidden.contains($0) }) }
            }
            if focusMode { updateDimming() }
            updateReveal(textView)
            if scrollView?.rulersVisible == true { scrollView?.verticalRulerView?.needsDisplay = true }
        }

        /// Keeps misspelling marks out of code, math, directive options, roles, labels and URLs.
        func textView(_ textView: NSTextView, shouldSetSpellingState value: Int, range affectedCharRange: NSRange) -> Int {
            guard value != 0 else { return value }
            return spellExcluded.excludes(affectedCharRange) ? 0 : value
        }
    }
}
