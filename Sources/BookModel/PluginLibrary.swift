import Foundation

/// A plugin in the user's library: a file kept in the library folder, or a URL.
public struct LibraryPlugin: Hashable, Identifiable, Sendable {
    public enum Source: Hashable, Sendable {
        case file(URL)
        case url(String)
    }

    public let source: Source

    public var id: String {
        switch source {
        case .file(let url): return url.path
        case .url(let address): return address
        }
    }

    /// The file name, or the last part of the URL.
    public var name: String {
        switch source {
        case .file(let url): return url.lastPathComponent
        case .url(let address): return URL(string: address)?.lastPathComponent ?? address
        }
    }

    public var isURL: Bool {
        if case .url = source { return true }
        return false
    }
}

/// Plugins for all books, kept like snippets: plain files in
/// `~/Library/Application Support/JupyterBookNook/Plugins`, and the URLs in `urls.txt` there.
/// Adding one to a book copies the file into the book's `plugins/` folder (or lists the URL).
public enum PluginLibrary {
    public static var folder: URL {
        #if DEBUG
        // Snapshot runs use a scratch library instead of the user's.
        if let path = ProcessInfo.processInfo.environment["NOOK_PLUGIN_LIBRARY"] { return URL(fileURLWithPath: path, isDirectory: true) }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("JupyterBookNook/Plugins", isDirectory: true)
    }

    static let urlsFileName = "urls.txt"
    public static let fileExtensions: Set<String> = ["mjs", "js", "cjs"]

    /// Files first (by name), then URLs in the order they were added.
    public static func plugins(in folder: URL = folder) -> [LibraryPlugin] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { fileExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { LibraryPlugin(source: .file($0)) }
        return files + urls(in: folder).map { LibraryPlugin(source: .url($0)) }
    }

    private static func urls(in folder: URL) -> [String] {
        let text = (try? String(contentsOf: folder.appendingPathComponent(urlsFileName), encoding: .utf8)) ?? ""
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private static func writeURLs(_ urls: [String], in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = "# Plugins by URL, one per line (JupyterBookNook's plugin library).\n" + urls.map { $0 + "\n" }.joined()
        try text.write(to: folder.appendingPathComponent(urlsFileName), atomically: true, encoding: .utf8)
    }

    /// Copies a plugin file into the library. A file with the same contents already there is
    /// returned instead; one with the same name but other contents gets a numbered name.
    @discardableResult
    public static func add(file url: URL, in folder: URL = folder) throws -> LibraryPlugin {
        let fm = FileManager.default
        let data = try Data(contentsOf: url)
        if let same = existing(sameAs: data, in: folder) { return same }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var target = folder.appendingPathComponent(url.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent(ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)")
            n += 1
        }
        try data.write(to: target, options: .atomic)
        return LibraryPlugin(source: .file(target))
    }

    @discardableResult
    public static func add(url address: String, in folder: URL = folder) throws -> LibraryPlugin {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = urls(in: folder)
        if !list.contains(address) {
            list.append(address)
            try writeURLs(list, in: folder)
        }
        return LibraryPlugin(source: .url(address))
    }

    /// Files are moved to the Trash, so a removal can be undone in the Finder.
    public static func remove(_ plugin: LibraryPlugin, in folder: URL = folder) throws {
        switch plugin.source {
        case .file(let url):
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        case .url(let address):
            try writeURLs(urls(in: folder).filter { $0 != address }, in: folder)
        }
    }

    /// The library plugin with these contents, if any.
    public static func existing(sameAs data: Data, in folder: URL = folder) -> LibraryPlugin? {
        plugins(in: folder).first { plugin in
            guard case .file(let url) = plugin.source else { return false }
            return (try? Data(contentsOf: url)) == data
        }
    }

    /// Whether a book plugin is already in the library: the same URL, or a file with the same contents.
    public static func contains(_ entry: PluginEntry, projectRoot: URL, in folder: URL = folder) -> Bool {
        if entry.isURL { return urls(in: folder).contains(entry.source) }
        guard !entry.isExecutable,
              let data = try? Data(contentsOf: projectRoot.appendingPathComponent(BookProject.normalized(entry.source))) else { return false }
        return existing(sameAs: data, in: folder) != nil
    }
}
