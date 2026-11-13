import CryptoKit
import Foundation

/// Brings the documentation copy (Help › JupyterBookNook Documentation) up to date with the pages
/// of this app version. `.jupyterbooknook-docs.json` in the copy records, for each file, the
/// version the app last offered and what it last wrote, so it can tell a page the user changed from
/// an older version of the app's own page:
/// - pages the user did not change are replaced, files the app no longer has are removed;
/// - pages the user changed are listed in `changedByUser`, and replaced only when asked;
/// - files the user deleted stay deleted; a version once declined is not offered again.
public struct DocumentationUpdate {
    public static let manifestName = ".jupyterbooknook-docs.json"

    struct Entry: Codable, Equatable {
        /// The hash of the app's version last written or offered.
        var offered: String
        /// The hash of what the app wrote, nil when the user's version was kept.
        var written: String?
    }

    public let folder: URL
    /// Changed by the user, with a new version from the app (paths relative to `folder`).
    public private(set) var changedByUser: [String] = []
    /// Written without asking: missing or not changed by the user.
    public private(set) var updates: [String] = []
    /// Removed: no longer part of the documentation and not changed by the user.
    public private(set) var removals: [String] = []
    private var contents: [String: String] = [:]
    private var manifest: [String: Entry]
    private let oldManifest: [String: Entry]

    /// Compares `folder` with `files` (as in `ProjectTemplate.files`, the pages in the folder for
    /// pages); nothing is written until `apply`.
    public init(folder: URL, files: [(path: String, contents: String)] = TemplateLibrary.documentation.files) {
        self.folder = folder
        let manifestURL = folder.appendingPathComponent(Self.manifestName)
        let old = (try? Data(contentsOf: manifestURL)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        oldManifest = old
        manifest = old
        let name = TemplateLibrary.documentationName
        let values = TemplateValues(title: name, book: name)
        let expected = TemplateLibrary.pages(of: files, in: BookProject.readFolders(in: folder).pages)
        for file in expected {
            let path = file.path
            let new = values.fill(file.contents, yaml: TemplateLibrary.isYAML(path))
            let hash = Self.hash(new)
            contents[path] = new
            let entry = old[path]
            guard let disk = try? String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8) else {
                // Missing: new in this version, or deleted by the user (then it stays deleted).
                if entry == nil { updates.append(path); manifest[path] = Entry(offered: hash, written: hash) }
                else { manifest[path]?.offered = hash }
                continue
            }
            if disk == new || (entry == nil && Self.withoutDate(disk) == new) {
                manifest[path] = Entry(offered: hash, written: Self.hash(disk))
            } else if entry == nil, Self.firstRelease.contains(Self.hash(disk)) {
                updates.append(path)
                manifest[path] = Entry(offered: hash, written: hash)
            } else if entry?.offered == hash {
                continue // this version was offered before
            } else if let written = entry?.written, written == Self.hash(disk) {
                updates.append(path)
                manifest[path] = Entry(offered: hash, written: hash)
            } else {
                changedByUser.append(path)
            }
        }
        for (path, entry) in old where contents[path] == nil {
            manifest[path] = nil
            if let disk = try? String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8),
               Self.hash(disk) == entry.written { removals.append(path) }
        }
        updates.sort()
        removals.sort()
    }

    /// Writes the updates and removals; the pages in `changedByUser` are replaced when
    /// `replacingChanges`, else kept (and their new version is not offered again).
    public func apply(replacingChanges: Bool) throws {
        let fm = FileManager.default
        var manifest = manifest
        func write(_ path: String) throws {
            let url = folder.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (contents[path] ?? "").write(to: url, atomically: true, encoding: .utf8)
        }
        for path in updates { try write(path) }
        for path in removals { try? fm.removeItem(at: folder.appendingPathComponent(path)) }
        for path in changedByUser {
            let hash = Self.hash(contents[path] ?? "")
            if replacingChanges {
                try write(path)
                manifest[path] = Entry(offered: hash, written: hash)
            } else {
                manifest[path] = Entry(offered: hash, written: oldManifest[path]?.written)
            }
        }
        guard manifest != oldManifest else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: folder.appendingPathComponent(Self.manifestName), options: .atomic)
    }

    /// Pages of the first documentation (before the manifest) that later versions changed, so
    /// copies made then count as unchanged: intro.md.
    static let firstRelease: Set<String> = ["4218f51747845800c2789c155303c556d72fe421b65d63c54ecc79177d7afb84"]

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Copies from before the manifest have the creation date in myst.yml's first comment.
    static func withoutDate(_ text: String) -> String {
        text.replacingOccurrences(of: #"documentation, created on \d{4}-\d{2}-\d{2}\."#, with: "documentation.", options: .regularExpression)
    }
}
