import AppKit
import BuildService
import MystSyntax
import PDFKit
import QuickLookUI
import SwiftUI
import WebKit

/// The live preview: the real MyST site from `myst start`, so the page looks as it does in a browser.
/// It follows the open tab, and MyST reloads it after every save.
struct PreviewPane: View {
    @Environment(BookStore.self) private var store
    @State private var reloadToken = 0

    var body: some View {
        let build = store.build
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .foregroundStyle(.secondary)
                Text(viewOnlyFile?.path ?? build.previewURL.map { pageURL(base: $0).absoluteString } ?? "Preview")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                if build.previewURL != nil {
                    Label("Live", systemImage: "circle.fill")
                        .labelStyle(LiveLabelStyle())
                        .help("Saved changes appear here within a second")
                }
                Toggle(isOn: Binding(get: { store.scrollSync.isEnabled }, set: { store.scrollSync.isEnabled = $0 })) {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .toggleStyle(.button)
                .help("Keep editor and preview on the same section (Split view)")
                Button {
                    reloadToken += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload")
                .disabled(build.previewURL == nil)
                Button {
                    if let url = build.previewURL { NSWorkspace.shared.open(pageURL(base: url)) }
                } label: {
                    Image(systemName: "safari")
                }
                .help("Open in Browser")
                .disabled(build.previewURL == nil)
                Button {
                    store.viewMode = .editor
                } label: {
                    Image(systemName: "xmark")
                }
                .help("Show only the editor (⌘1); the preview keeps running in the background")
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.bar)
            Divider()
            content
        }
    }

    /// The open tab when the preview shows it instead of the book: a file shown as it is (PDF,
    /// image, SVG) or a file without a preview (myst.yml, a plugin…).
    private var viewOnlyFile: OpenDocument? {
        guard let document = store.currentDocument, document.previewKind != .site, store.settingsTab == nil else { return nil }
        return document
    }

    @ViewBuilder
    private var content: some View {
        if let document = viewOnlyFile {
            if document.previewKind == .file {
                // A PDF, image or SVG tab: the file itself, not the book. An SVG edited here is
                // shown again after each save.
                FilePreview(url: document.url, revision: document.diskRevision &+ document.savedText.hashValue)
            } else {
                ContentUnavailableView {
                    Label("No preview available", systemImage: "eye.slash")
                } description: {
                    Text("\(document.fileName) is not a page of the book. Open a page to see it here.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            sitePreview
        }
    }

    @ViewBuilder
    private var sitePreview: some View {
        switch store.build.previewState {
        case .running(let base):
            PreviewWebView(url: pageURL(base: base), contentPort: store.build.previewContentPort,
                           reloadToken: reloadToken + store.build.previewReloadRevision, styleRevision: store.build.previewStyleRevision, scrollSync: store.scrollSync)
                // A restarted server has new ports, and the injected script needs the new one.
                .id(base)
        case .starting:
            VStack(spacing: 10) {
                ProgressView()
                Text("Starting the preview…")
                Text("The first start of a book downloads its theme, which needs an internet connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let reason):
            ContentUnavailableView {
                Label("The preview stopped", systemImage: "exclamationmark.triangle")
            } description: {
                Text(reason).font(.caption.monospaced())
            } actions: {
                Button("Try Again") { store.build.restartPreview() }
                Button("Show Log") {
                    store.build.panelTab = .log
                    store.build.isShowingPanel = true
                }
            }
        case .stopped:
            ContentUnavailableView {
                Label("No preview", systemImage: "eye.slash")
            } description: {
                Text("The preview needs MyST.")
            } actions: {
                Button("Set Up MyST…") { store.build.isShowingSetup = true }
                Button("Start Preview") { store.build.restartPreview() }
            }
        }
    }

    /// The preview page for the open tab.
    private func pageURL(base: URL) -> URL {
        guard let project = store.project else { return base }
        let pages = project.toc.allFiles.map { $0.hasSuffix(".md") || $0.hasSuffix(".ipynb") ? $0 : $0 + ".md" }
        return store.build.previewURL(for: store.currentPath, pages: pages, root: project.root) ?? base
    }
}

struct PreviewWebView: NSViewRepresentable {
    let url: URL
    let contentPort: Int?
    let reloadToken: Int
    let styleRevision: Int
    let scrollSync: ScrollSync

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if let contentPort {
            // Live changes refresh the page in place instead of reloading it, so it does not flash.
            configuration.userContentController.addUserScript(WKUserScript(
                source: PreviewScripts.liveRefresh(contentPort: contentPort),
                injectionTime: .atDocumentStart, forMainFrameOnly: true
            ))
        }
        configuration.userContentController.addUserScript(WKUserScript(
            source: PreviewScripts.scrollSync, injectionTime: .atDocumentEnd, forMainFrameOnly: true
        ))
        // A weak proxy: the content controller would otherwise keep the coordinator alive.
        configuration.userContentController.add(WeakMessageHandler(context.coordinator), name: PreviewScripts.syncHandlerName)
        context.coordinator.scrollSync = scrollSync
        let webView = WKWebView(frame: .zero, configuration: configuration)
        context.coordinator.webView = webView
        scrollSync.highlightPreview = { [weak webView] selection in
            guard let selection else {
                webView?.evaluateJavaScript("window.__nookHighlight && window.__nookHighlight()")
                return
            }
            // The text as a JSON string literal.
            let text = (try? JSONSerialization.data(withJSONObject: [selection.text])).flatMap { String(data: $0, encoding: .utf8) }
                .map { String($0.dropFirst().dropLast()) } ?? "\"\""
            webView?.evaluateJavaScript("window.__nookHighlight && window.__nookHighlight(\(selection.start), \(selection.end), \(text))")
        }
        scrollSync.scrollPreview = { [weak webView] line, heading, animated, end in
            let lineValue = line.map { String(format: "%.2f", $0) } ?? "null"
            webView?.evaluateJavaScript("window.__nookScrollToLine && window.__nookScrollToLine(\(lineValue), \(heading), \(animated), \(String(format: "%.3f", end)))")
        }
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.requested = url
        context.coordinator.reloadToken = reloadToken
        context.coordinator.styleRevision = styleRevision
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Load only when the requested page changes, so links followed inside the preview stick.
        if context.coordinator.requested != url {
            context.coordinator.requested = url
            webView.load(URLRequest(url: url))
        } else if context.coordinator.reloadToken != reloadToken {
            context.coordinator.reloadToken = reloadToken
            webView.reload()
        } else if context.coordinator.styleRevision != styleRevision {
            context.coordinator.styleRevision = styleRevision
            webView.evaluateJavaScript(PreviewScripts.reloadStylesheet)
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: PreviewScripts.syncHandlerName)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        var requested: URL?
        var reloadToken = 0
        var styleRevision = 0
        weak var webView: WKWebView?
        weak var scrollSync: ScrollSync?

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "scroll":
                if let index = body["index"] as? Int { scrollSync?.previewScrolled(toHeading: index, line: body["line"] as? Double, end: body["end"] as? Double ?? 0) }
            case "selection":
                let text = body["text"] as? String ?? ""
                if text.isEmpty {
                    scrollSync?.previewSelectionChanged(nil)
                } else if let start = body["start"] as? Int, let end = body["end"] as? Int {
                    scrollSync?.previewSelectionChanged(.init(start: start, end: max(start, end), text: text))
                }
            case "anchors":
                scrollSync?.previewAnchorsChanged(count: body["count"] as? Int ?? 0, blocks: body["blocks"] as? Int ?? 0)
            case "headings":
                let items = (body["items"] as? [[String: Any]] ?? []).map { item in
                    PreviewHeading(id: item["id"] as? String ?? "", text: item["text"] as? String ?? "", level: item["level"] as? Int ?? 2)
                }
                scrollSync?.previewHeadingsChanged(items, initial: body["initial"] as? Bool ?? false)
            default:
                break
            }
        }
    }
}

/// Forwards script messages without the content controller retaining the receiver.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// A small green dot before the label, as in "● Live".
struct LiveLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
                .font(.system(size: 7))
                .foregroundStyle(.green)
            configuration.title
                .foregroundStyle(.green)
        }
    }
}

/// A file shown in the preview: PDFs with PDFKit (pages to scroll), images scaled to fit, and
/// anything else with Quick Look.
struct FilePreview: View {
    let url: URL
    /// Changes when the file changed on disk, to show it again.
    let revision: Int

    var body: some View {
        let ext = url.pathExtension.lowercased()
        Group {
            if ext == "pdf" {
                PDFFileView(url: url, revision: revision)
            } else if let image = NSImage(contentsOf: url), image.isValid {
                // Drawings (SVG) scale to the pane; pixel images up to their own size.
                let isVector = image.representations.contains { $0 is NSPDFImageRep || String(describing: type(of: $0)).contains("SVG") }
                GeometryReader { geometry in
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        // On white, as on a page: drawings are often transparent with black lines.
                        .background(Color.white)
                        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                        .frame(maxWidth: isVector ? .infinity : max(image.size.width, 1),
                               maxHeight: isVector ? .infinity : max(image.size.height, 1))
                        .padding(20)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .id(revision)
            } else {
                QuickLookFileView(url: url, revision: revision)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

private struct PDFFileView: NSViewRepresentable {
    let url: URL
    let revision: Int

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .underPageBackgroundColor
        show(in: view, context: context)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard context.coordinator.shown.url != url || context.coordinator.shown.revision != revision else { return }
        show(in: view, context: context)
    }

    private func show(in view: PDFView, context: Context) {
        context.coordinator.shown = (url, revision)
        view.document = PDFDocument(url: url)
    }

    func makeCoordinator() -> Shown { Shown() }
}

private struct QuickLookFileView: NSViewRepresentable {
    let url: URL
    let revision: Int

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        context.coordinator.shown = (url, revision)
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard context.coordinator.shown.url != url || context.coordinator.shown.revision != revision else { return }
        context.coordinator.shown = (url, revision)
        view.previewItem = url as NSURL
        view.refreshPreviewItem()
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: Shown) {
        view.close()
    }

    func makeCoordinator() -> Shown { Shown() }
}

/// What a file view shows, so it loads the file again only when it changed.
final class Shown {
    var shown: (url: URL?, revision: Int) = (nil, 0)
}
