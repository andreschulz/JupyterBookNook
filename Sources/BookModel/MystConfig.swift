import Foundation
import Yams

public enum MystConfigError: LocalizedError, Equatable {
    case notAMapping
    case tocNotAList
    case invalidTOCEntry(String)

    public var errorDescription: String? {
        switch self {
        case .notAMapping: return "myst.yml does not contain a YAML mapping."
        case .tocNotAList: return "project.toc in myst.yml must be a list."
        case .invalidTOCEntry(let text): return "Invalid table-of-contents entry in myst.yml: \(text)"
        }
    }
}

/// The parts of `myst.yml` the app reads. The file itself stays the source of truth;
/// this is a read-only view of it, rebuilt after every change.
public struct MystConfig {
    public var version: Int?
    public var title: String?
    /// `nil` when `myst.yml` has no `project.toc`; Jupyter Book then infers the order from the files.
    public var toc: [TOCEntry]?
    public var plugins: [String]
    /// `project.bibliography`: a file or a list of files.
    public var bibliography: [String]

    /// No settings: what the app works with while myst.yml cannot be read.
    public init() {
        plugins = []
        bibliography = []
    }

    public init(yaml: String) throws {
        guard let root = try Yams.compose(yaml: yaml), root.mapping != nil else {
            throw MystConfigError.notAMapping
        }
        version = root["version"]?.int
        let project = root["project"]
        title = project?["title"]?.string
        if let tocNode = project?["toc"] {
            var ids = StableIDs()
            toc = try Self.parseTOC(tocNode, ids: &ids)
        } else {
            toc = nil
        }
        plugins = project?["plugins"]?.sequence?.compactMap { $0.string ?? $0["path"]?.string } ?? []
        if let list = project?["bibliography"]?.sequence {
            bibliography = list.compactMap { $0.string }
        } else {
            bibliography = project?["bibliography"]?.string.map { [$0] } ?? []
        }
    }

    static func parseTOC(_ node: Node, ids: inout StableIDs) throws -> [TOCEntry] {
        guard let items = node.sequence else { throw MystConfigError.tocNotAList }
        return try items.map { item in
            guard item.mapping != nil else {
                throw MystConfigError.invalidTOCEntry(item.string ?? "(not a mapping)")
            }
            let kind: TOCEntry.Kind
            if let file = item["file"]?.string {
                kind = .file(file)
            } else if let pattern = item["pattern"]?.string {
                kind = .pattern(pattern)
            } else if let url = item["url"]?.string {
                kind = .url(url)
            } else {
                kind = .group
            }
            let title = item["title"]?.string
            let id = ids.next(for: kind, title: title)
            let children = try item["children"].map { try parseTOC($0, ids: &ids) } ?? []
            return TOCEntry(
                kind: kind,
                title: title,
                hidden: item["hidden"]?.bool ?? false,
                children: children,
                id: id
            )
        }
    }
}

/// Why myst.yml cannot be read, with the line of the problem when the YAML parser gives one.
public struct ConfigProblem: Equatable, Sendable {
    public var message: String
    /// 1-based.
    public var line: Int?

    public init(message: String, line: Int? = nil) {
        self.message = message
        self.line = line
    }

    public init(_ error: Error) {
        switch error {
        case YamlError.scanner(_, let problem, let mark, _),
             YamlError.parser(_, let problem, let mark, _),
             YamlError.composer(_, let problem, let mark, _):
            self.init(message: problem.prefix(1).uppercased() + problem.dropFirst(), line: mark.line)
        case YamlError.duplicatedKeysInMapping:
            self.init(message: "A key appears twice in the same mapping")
        default:
            self.init(message: error.localizedDescription)
        }
    }

    public var description: String {
        line.map { "\(message) (line \($0))" } ?? message
    }
}

/// Entry ids derived from what an entry is (its file, pattern, url or part title), so the same
/// entry keeps its id when myst.yml is re-read. The sidebar relies on this to keep parts expanded.
struct StableIDs {
    private var seen: [String: Int] = [:]

    mutating func next(for kind: TOCEntry.Kind, title: String?) -> UUID {
        let key: String
        switch kind {
        case .file(let path): key = "file:" + path
        case .pattern(let pattern): key = "pattern:" + pattern
        case .url(let url): key = "url:" + url
        case .group: key = "group:" + (title ?? "")
        }
        let n = seen[key, default: 0]
        seen[key] = n + 1
        return Self.uuid(from: "\(key)#\(n)")
    }

    /// A deterministic UUID from two 64-bit FNV-1a hashes of `string`.
    static func uuid(from string: String) -> UUID {
        func fnv(_ seed: UInt64) -> UInt64 {
            var hash = seed
            for byte in string.utf8 {
                hash ^= UInt64(byte)
                hash &*= 0x100000001b3
            }
            return hash
        }
        let a = fnv(0xcbf29ce484222325), b = fnv(0x84222325cbf29ce4)
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            bytes[i] = UInt8(truncatingIfNeeded: a >> (8 * UInt64(i)))
            bytes[8 + i] = UInt8(truncatingIfNeeded: b >> (8 * UInt64(i)))
        }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
