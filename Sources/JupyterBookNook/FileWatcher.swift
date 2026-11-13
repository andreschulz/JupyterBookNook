import CoreServices
import Foundation

/// Reports changes to files in the book folder (FSEvents), so edits made in other apps, `git pull`
/// and new files show up without reopening the book. Changes are collected for a moment and
/// delivered on the main thread as paths relative to the folder; build output is left out.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let root: URL
    private let onChange: @MainActor (Set<String>) -> Void

    /// Folders whose changes never matter to the editor.
    static let ignoredFolders: Set<String> = ["_build", "node_modules", ".git", "__pycache__", ".ipynb_checkpoints"]

    init(root: URL, onChange: @escaping @MainActor (Set<String>) -> Void) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.onChange = onChange
        start()
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private func start() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.received(Array(list.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func received(_ paths: [String]) {
        let prefix = root.path + "/"
        var changed: Set<String> = []
        for path in paths {
            // FSEvents reports resolved paths (/private/var/…); the root was resolved the same way.
            let full = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            guard full.hasPrefix(prefix) else { continue }
            let relative = String(full.dropFirst(prefix.count))
            let components = relative.split(separator: "/").map(String.init)
            guard !components.contains(where: { Self.ignoredFolders.contains($0) || $0.hasPrefix(".") }) else { continue }
            changed.insert(relative)
        }
        guard !changed.isEmpty else { return }
        MainActor.assumeIsolated { onChange(changed) }
    }
}
