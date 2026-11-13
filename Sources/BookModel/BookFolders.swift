import Foundation

/// Where the app puts new files of a book: pages, figures, downloads and plugins, each in a folder
/// relative to the book folder ("" for the book folder itself). Other files (BibTeX, CSS) go into
/// the book folder. Existing files are never moved.
///
/// Kept in `.jupyterbooknook.yml` next to `myst.yml`, not in `myst.yml`: MyST warns about every
/// key it does not know on every build. The file travels with the book (git, copies, templates).
public struct BookFolders: Equatable, Sendable {
    public var pages: String
    public var figures: String
    public var downloads: String
    public var plugins: String

    public init(pages: String = "content", figures: String = "figs", downloads: String = "download", plugins: String = "plugins") {
        self.pages = pages
        self.figures = figures
        self.downloads = downloads
        self.plugins = plugins
    }

    public static let defaults = BookFolders()

    /// The folders that are set, for messages: "content, figs, download and plugins".
    public var all: [String] { [pages, figures, downloads, plugins].filter { !$0.isEmpty } }
    public static let fileName = ".jupyterbooknook.yml"

    /// The keys in the file, with the folder each one sets.
    static let keys: [(key: String, folder: WritableKeyPath<BookFolders, String>)] = [
        ("pages", \.pages), ("figures", \.figures), ("downloads", \.downloads), ("plugins", \.plugins),
    ]

    /// Reads `folders:` from the file's text; missing or invalid entries keep their default.
    public init(yaml: String) {
        self.init()
        for (key, folder) in Self.keys {
            if let value = YAMLEditor.value(at: ["folders", key], in: yaml)?.string, let valid = try? Self.validated(value) {
                self[keyPath: folder] = valid
            }
        }
    }

    /// The file's text with these folders, keeping anything else in `text`.
    public func yaml(updating text: String) throws -> String {
        var result = text.isEmpty ? "# JupyterBookNook settings for this book. MyST does not read this file.\n" : text
        for (key, folder) in Self.keys {
            let value = self[keyPath: folder]
            result = try YAMLEditor.setting(["folders", key], to: value == Self.defaults[keyPath: folder] ? nil : .string(value), in: result)
        }
        return result
    }

    /// `path` as a folder inside the book: no leading or trailing slashes, no `..`, hidden or build
    /// folders. "" and "." mean the book folder.
    public static func validated(_ path: String) throws -> String {
        let parts = path.trimmingCharacters(in: .whitespaces).split(separator: "/").filter { $0 != "." }
        guard !parts.contains(where: { $0 == ".." || $0.hasPrefix(".") || BookProject.skippedFolders.contains(String($0)) }) else {
            throw BookProjectError.invalidFolder(path)
        }
        return parts.joined(separator: "/")
    }
}

extension BookProject {
    /// `name` inside `folder` ("" for the book folder).
    public static func path(in folder: String, _ name: String) -> String {
        folder.isEmpty ? name : folder + "/" + name
    }

    public var foldersURL: URL { root.appendingPathComponent(BookFolders.fileName) }

    /// The folders `.jupyterbooknook.yml` in `root` sets, else the defaults.
    public static func readFolders(in root: URL) -> BookFolders {
        (try? String(contentsOf: root.appendingPathComponent(BookFolders.fileName), encoding: .utf8)).map(BookFolders.init(yaml:)) ?? .defaults
    }

    /// Changes where new files go, as one undoable change. Folders equal to the defaults are
    /// left out of the file; a file that would be empty of settings is not created.
    @discardableResult
    public mutating func setFolders(_ newFolders: BookFolders) throws -> StructuralChange? {
        var checked = newFolders
        for (_, folder) in BookFolders.keys { checked[keyPath: folder] = try BookFolders.validated(newFolders[keyPath: folder]) }
        guard checked != folders else { return nil }
        let existing = try? String(contentsOf: foldersURL, encoding: .utf8)
        let text = try checked.yaml(updating: existing ?? "")
        let operation: FileOperation = existing.map { .edited(foldersURL, before: $0, after: text) } ?? .created(foldersURL, contents: text)
        return try commit(toc: nil, operations: [operation], summary: "Folders for new files changed — \(BookFolders.fileName) updated")
    }
}
