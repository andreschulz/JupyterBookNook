import Foundation

/// One file-system step of a structural change. Every operation has an inverse,
/// so a change can be undone and redone.
public enum FileOperation: Equatable {
    /// Writes a new file; the file must not exist yet.
    case created(URL, contents: String)
    /// Removes a file whose contents are known, so it can be recreated.
    case deleted(URL, contents: String)
    /// Writes a new file with any contents (an image, a copied page); the file must not exist yet.
    case createdData(URL, Data)
    /// Removes a file whose bytes are known, so it can be recreated.
    case deletedData(URL, Data)
    /// Renames or moves a file; `to` must not exist yet. Moving to the Trash is a move too.
    case moved(from: URL, to: URL)
    /// Replaces a file's text; refused when the file no longer contains `before`.
    case edited(URL, before: String, after: String)
    /// Moves a file to the Trash. Performing it records a `.moved` to the Trash location.
    case trashed(URL)
    /// A folder created for a new or moved file, recorded so undo can remove it again.
    case createdFolder(URL)
    /// Removes a folder if it is empty; a folder that still has files is left alone.
    case removedFolder(URL)
}

/// A structural change to the book (files plus `myst.yml`) that can be undone as one step.
public struct StructuralChange {
    public var summary: String
    public var configBefore: String
    public var configAfter: String
    /// The operations as they were performed, in order.
    public var fileOperations: [FileOperation]

    public var changesConfig: Bool { configBefore != configAfter }

    /// Moves and renames inside the project as (from, to) URLs, in order.
    public var moves: [(from: URL, to: URL)] {
        fileOperations.compactMap { op in
            if case .moved(let from, let to) = op { return (from, to) }
            return nil
        }
    }
}

public enum FileOperationError: LocalizedError, Equatable {
    case alreadyExists(String)
    case missing(String)
    case changedSince(String)
    case trashUnavailable

    public var errorDescription: String? {
        switch self {
        case .alreadyExists(let name): return "“\(name)” already exists."
        case .missing(let name): return "“\(name)” no longer exists, so this cannot be done automatically."
        case .changedSince(let name): return "“\(name)” was changed after this action, so it cannot be undone automatically."
        case .trashUnavailable: return "Moving files to the Trash is not available on this system."
        }
    }
}

/// Performs file operations and rolls back the ones already done when a later one fails.
struct FileOperationRunner {
    var trash: (URL) throws -> URL
    private let fileManager = FileManager.default

    /// Performs `operations` in order and returns what was actually done.
    func perform(_ operations: [FileOperation]) throws -> [FileOperation] {
        var done: [FileOperation] = []
        do {
            for op in operations {
                try done.append(contentsOf: perform(op))
            }
        } catch {
            rollBack(done)
            throw error
        }
        return done
    }

    /// Undoes performed operations, last first, ignoring failures (used on error paths).
    func rollBack(_ performed: [FileOperation]) {
        for op in performed.reversed() {
            if let inverse = try? inverse(of: op) {
                _ = try? perform(inverse)
            }
        }
    }

    /// The operation that undoes `op`. A created file is deleted with whatever it contains now,
    /// so redoing brings back edits made in between.
    func inverse(of op: FileOperation) throws -> FileOperation {
        switch op {
        case .created(let url, _):
            guard let current = try? String(contentsOf: url, encoding: .utf8) else {
                throw FileOperationError.missing(url.lastPathComponent)
            }
            return .deleted(url, contents: current)
        case .deleted(let url, let contents):
            return .created(url, contents: contents)
        case .createdData(let url, _):
            guard let current = try? Data(contentsOf: url) else {
                throw FileOperationError.missing(url.lastPathComponent)
            }
            return .deletedData(url, current)
        case .deletedData(let url, let data):
            return .createdData(url, data)
        case .moved(let from, let to):
            return .moved(from: to, to: from)
        case .edited(let url, let before, let after):
            return .edited(url, before: after, after: before)
        case .trashed(let url):
            throw FileOperationError.missing(url.lastPathComponent) // never recorded; `.moved` is
        case .createdFolder(let url):
            return .removedFolder(url)
        case .removedFolder(let url):
            return .createdFolder(url)
        }
    }

    /// Performs one operation; returns it plus any folders it had to create (those first).
    private func perform(_ op: FileOperation) throws -> [FileOperation] {
        switch op {
        case .created(let url, let contents):
            guard !fileManager.fileExists(atPath: url.path) else {
                throw FileOperationError.alreadyExists(url.lastPathComponent)
            }
            let folders = try createFolders(for: url)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return folders + [op]
        case .deleted(let url, _), .deletedData(let url, _):
            guard fileManager.fileExists(atPath: url.path) else {
                throw FileOperationError.missing(url.lastPathComponent)
            }
            try fileManager.removeItem(at: url)
            return [op]
        case .createdData(let url, let data):
            guard !fileManager.fileExists(atPath: url.path) else {
                throw FileOperationError.alreadyExists(url.lastPathComponent)
            }
            let folders = try createFolders(for: url)
            try data.write(to: url, options: .atomic)
            return folders + [op]
        case .moved(let from, let to):
            guard fileManager.fileExists(atPath: from.path) else {
                throw FileOperationError.missing(from.lastPathComponent)
            }
            guard !fileManager.fileExists(atPath: to.path) else {
                throw FileOperationError.alreadyExists(to.lastPathComponent)
            }
            let folders = try createFolders(for: to)
            try fileManager.moveItem(at: from, to: to)
            return folders + [op]
        case .edited(let url, let before, let after):
            guard let current = try? String(contentsOf: url, encoding: .utf8) else {
                throw FileOperationError.missing(url.lastPathComponent)
            }
            guard current == before else { throw FileOperationError.changedSince(url.lastPathComponent) }
            try after.write(to: url, atomically: true, encoding: .utf8)
            return [op]
        case .trashed(let url):
            guard fileManager.fileExists(atPath: url.path) else {
                throw FileOperationError.missing(url.lastPathComponent)
            }
            return [.moved(from: url, to: try trash(url))]
        case .createdFolder(let url):
            if !fileManager.fileExists(atPath: url.path) {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
            }
            return [op]
        case .removedFolder(let url):
            if (try? fileManager.contentsOfDirectory(atPath: url.path))?.isEmpty == true {
                try fileManager.removeItem(at: url)
            }
            return [op]
        }
    }

    /// Creates the missing folders above `file`, outermost first, and records each one.
    private func createFolders(for file: URL) throws -> [FileOperation] {
        var missing: [URL] = []
        var folder = file.deletingLastPathComponent()
        while !fileManager.fileExists(atPath: folder.path), folder.pathComponents.count > 1 {
            missing.insert(folder, at: 0)
            folder = folder.deletingLastPathComponent()
        }
        for url in missing {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        }
        return missing.map { .createdFolder($0) }
    }

    /// The system Trash on macOS.
    static func systemTrash(_ url: URL) throws -> URL {
        #if os(macOS)
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        guard let result = resulting as URL? else { throw FileOperationError.trashUnavailable }
        return result
        #else
        throw FileOperationError.trashUnavailable
        #endif
    }
}
