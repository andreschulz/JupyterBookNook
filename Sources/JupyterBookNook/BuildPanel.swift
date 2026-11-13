import BuildService
import SwiftUI

/// The panel under the editor: the build's problems, linked to their pages, and the raw log.
struct BuildPanel: View {
    @Environment(BookStore.self) private var store

    var body: some View {
        @Bindable var build = store.build
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                status
                Spacer()
                Picker("", selection: $build.panelTab) {
                    ForEach(BuildController.PanelTab.allCases, id: \.self) { tab in
                        Text(tab == .problems ? "Problems (\(messages.count))" : tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button {
                    build.isShowingPanel = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Hide the build panel")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
            Divider()
            switch build.panelTab {
            case .problems: problemList
            case .log: logView
            }
        }
    }

    /// Problems from the last build, or from the preview while no build has run.
    private var messages: [BuildMessage] {
        if case .idle = store.build.buildState { return store.build.previewMessages }
        return store.build.buildMessages
    }

    @ViewBuilder
    private var status: some View {
        let build = store.build
        let toolchain = build.toolchain(for: store.project?.root)
        HStack(spacing: 6) {
            switch build.buildState {
            case .idle:
                Image(systemName: "hammer").foregroundStyle(.secondary)
                Text(build.isPreviewActive ? "Preview" : "Not built yet")
            case .running:
                ProgressView().controlSize(.small)
                Text("Building…")
            case .finished(let succeeded, let duration):
                Image(systemName: succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(succeeded ? .green : .red)
                Text(succeeded ? "Built in \(duration, format: .number.precision(.fractionLength(1))) s" : "Build failed")
            case .failed(let reason):
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text(reason).lineLimit(1).help(reason)
            }
            counts
            if let toolchain {
                Text("· \(toolchain.tool.rawValue) \(build.versions[toolchain] ?? "")")
                    .foregroundStyle(.secondary)
                    .help(toolchain.displayName)
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private var counts: some View {
        let errors = messages.filter { $0.severity == .error }.count
        let warnings = messages.filter { $0.severity == .warning }.count
        if errors > 0 {
            Label("\(errors)", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
        if warnings > 0 {
            Label("\(warnings)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var problemList: some View {
        if messages.isEmpty {
            ContentUnavailableView {
                Label(store.build.isBuilding ? "Building…" : "No problems", systemImage: "checkmark.seal")
            } description: {
                Text("Warnings and errors from MyST appear here, linked to their pages.")
            }
        } else {
            List(messages) { message in
                MessageRow(message: message)
                    .contentShape(Rectangle())
                    .onTapGesture { store.showMessage(message) }
                    .help(message.file.map { "Open \($0)" } ?? "")
            }
            .listStyle(.plain)
        }
    }

    private var logView: some View {
        let lines = store.build.buildLog.isEmpty ? store.build.previewLog : store.build.buildLog
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(8)
            }
            .onChange(of: lines.count) { _, count in
                if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
    }
}

struct MessageRow: View {
    let message: BuildMessage

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: message.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(message.severity == .error ? .red : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.text)
                    .textSelection(.enabled)
                if !message.detail.isEmpty {
                    Text(message.detail.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let file = message.file {
                Text(message.line.map { "\(file):\($0)" } ?? file)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
