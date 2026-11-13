import Foundation

/// One entry of `project.toc` in `myst.yml`.
///
/// Jupyter Book 2 entries are mappings with one of `file`, `pattern` or `url`,
/// or a bare `title` with `children` (a part / group).
public struct TOCEntry: Identifiable, Hashable {
    public enum Kind: Hashable {
        case file(String)
        case pattern(String)
        case url(String)
        case group
    }

    public let id: UUID
    public var kind: Kind
    public var title: String?
    public var hidden: Bool
    public var children: [TOCEntry]

    public init(kind: Kind, title: String? = nil, hidden: Bool = false, children: [TOCEntry] = [], id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        self.title = title
        self.hidden = hidden
        self.children = children
    }

    public static func file(_ path: String, title: String? = nil, children: [TOCEntry] = []) -> TOCEntry {
        TOCEntry(kind: .file(path), title: title, children: children)
    }

    public static func group(_ title: String, children: [TOCEntry] = []) -> TOCEntry {
        TOCEntry(kind: .group, title: title, children: children)
    }

    public var file: String? {
        if case .file(let path) = kind { return path }
        return nil
    }

    public var isGroup: Bool { kind == .group }

    /// `nil` for leaves, so SwiftUI's `OutlineGroup` shows no disclosure triangle.
    public var childrenOrNil: [TOCEntry]? { children.isEmpty ? nil : children }
}

extension Array where Element == TOCEntry {
    /// Every `file` path in the tree, depth first, in book order.
    public var allFiles: [String] {
        flatMap { entry in (entry.file.map { [$0] } ?? []) + entry.children.allFiles }
    }

    public var allPatterns: [String] {
        flatMap { entry -> [String] in
            var own: [String] = []
            if case .pattern(let p) = entry.kind { own = [p] }
            return own + entry.children.allPatterns
        }
    }

    /// Every group (part) in the tree, depth first.
    public var allGroups: [TOCEntry] {
        flatMap { entry in (entry.isGroup ? [entry] : []) + entry.children.allGroups }
    }

    /// Appends `entry` to the children of the entry with `parentID`, or to the top level when `parentID` is nil.
    /// Returns false when no entry has that id.
    @discardableResult
    public mutating func appendEntry(_ entry: TOCEntry, under parentID: UUID?) -> Bool {
        guard let parentID else {
            append(entry)
            return true
        }
        for i in indices {
            if self[i].id == parentID {
                self[i].children.append(entry)
                return true
            }
            if self[i].children.appendEntry(entry, under: parentID) {
                return true
            }
        }
        return false
    }

    /// Removes and returns the entry with `id`, searching the whole tree.
    @discardableResult
    public mutating func removeEntry(id: UUID) -> TOCEntry? {
        if let i = firstIndex(where: { $0.id == id }) {
            return remove(at: i)
        }
        for i in indices {
            if let removed = self[i].children.removeEntry(id: id) {
                return removed
            }
        }
        return nil
    }
}

extension Array where Element == TOCEntry {
    /// The entry with `id`, anywhere in the tree.
    public func entry(id: UUID) -> TOCEntry? {
        for entry in self {
            if entry.id == id { return entry }
            if let found = entry.children.entry(id: id) { return found }
        }
        return nil
    }

    /// Where the entry with `id` sits: its parent's id (nil at the top level) and its index there.
    public func location(of id: UUID) -> (parent: UUID?, index: Int)? {
        location(of: id, parent: nil)
    }

    private func location(of id: UUID, parent: UUID?) -> (parent: UUID?, index: Int)? {
        for (i, entry) in enumerated() {
            if entry.id == id { return (parent, i) }
            if let found = entry.children.location(of: id, parent: entry.id) { return found }
        }
        return nil
    }

    /// The children of `parent` (the top level when nil), or nil when no entry has that id.
    public func children(of parent: UUID?) -> [TOCEntry]? {
        guard let parent else { return self }
        return entry(id: parent)?.children
    }

    /// Inserts `entry` into the children of `parent` (the top level when nil) at `index`, clamped.
    @discardableResult
    public mutating func insertEntry(_ entry: TOCEntry, under parent: UUID?, at index: Int) -> Bool {
        guard let parent else {
            insert(entry, at: Swift.min(Swift.max(index, 0), count))
            return true
        }
        for i in indices {
            if self[i].id == parent {
                let children = self[i].children
                self[i].children.insert(entry, at: Swift.min(Swift.max(index, 0), children.count))
                return true
            }
            if self[i].children.insertEntry(entry, under: parent, at: index) { return true }
        }
        return false
    }

    /// Replaces the entry with `id` by its children, so they stay in the book at its position.
    @discardableResult
    public mutating func dissolveEntry(id: UUID) -> TOCEntry? {
        if let i = firstIndex(where: { $0.id == id }) {
            let removed = remove(at: i)
            insert(contentsOf: removed.children, at: i)
            return removed
        }
        for i in indices {
            if let removed = self[i].children.dissolveEntry(id: id) { return removed }
        }
        return nil
    }

    /// Calls `body` on every entry in the tree, allowing changes.
    public mutating func updateAll(_ body: (inout TOCEntry) -> Void) {
        for i in indices {
            body(&self[i])
            self[i].children.updateAll(body)
        }
    }
}

extension TOCEntry {
    /// True when `id` is this entry or one of its descendants.
    public func contains(_ id: UUID) -> Bool {
        self.id == id || children.contains { $0.contains(id) }
    }
}
