import Foundation
import Yams

/// A YAML value the app writes into `myst.yml`.
public indirect enum YAMLValue: Equatable, Sendable {
    /// A string, quoted when needed.
    case string(String)
    /// Written as is: booleans and numbers (`true`, `3`).
    case plain(String)
    case list([YAMLValue])
    case map([YAMLPair])

    public static func bool(_ value: Bool) -> YAMLValue { .plain(value ? "true" : "false") }

    /// Converts a parsed node, keeping key order. Tags and anchors are not kept.
    public init(node: Node) {
        switch node {
        case .scalar(let scalar):
            switch scalar.style {
            case .singleQuoted, .doubleQuoted, .literal, .folded:
                self = .string(scalar.string)
            default:
                if node.bool != nil || node.int != nil || node.float != nil || node.null != nil {
                    self = .plain(scalar.string)
                } else {
                    self = .string(scalar.string)
                }
            }
        case .sequence(let sequence):
            self = .list(sequence.map(YAMLValue.init(node:)))
        case .mapping(let mapping):
            self = .map(mapping.map { YAMLPair($0.key.string ?? "", YAMLValue(node: $0.value)) })
        case .alias:
            self = .plain("null")
        }
    }

    public var string: String? {
        switch self {
        case .string(let s), .plain(let s): return s
        default: return nil
        }
    }

    public var pairs: [YAMLPair]? {
        if case .map(let pairs) = self { return pairs }
        return nil
    }

    public subscript(key: String) -> YAMLValue? {
        pairs?.first { $0.key == key }?.value
    }
}

public struct YAMLPair: Equatable, Sendable {
    public var key: String
    public var value: YAMLValue

    public init(_ key: String, _ value: YAMLValue) {
        self.key = key
        self.value = value
    }
}

public enum YAMLEditorError: LocalizedError, Equatable {
    /// A mapping on the path is written inline (`site: {template: x}`) and cannot be edited line by line.
    case inlineMapping(String)

    public var errorDescription: String? {
        switch self {
        case .inlineMapping(let key):
            return "myst.yml writes `\(key)` on one line. Please write it as a block (one key per line), so the app can change it."
        }
    }
}

/// Sets or removes one key of a YAML file as a minimal text edit. Only the lines of that key
/// change; comments, key order and everything else are kept byte for byte.
///
/// Mappings must be written as blocks (one key per line). Values that are replaced may be
/// written in any form; the new value is written as a block.
public enum YAMLEditor {

    /// Returns `text` with the key at `path` set to `value`, or removed when `value` is nil.
    /// Missing parent mappings are created; mappings left empty by a removal are removed too.
    /// A new key in `project` goes before `toc`, so it stays near the other settings.
    public static func setting(_ path: [String], to value: YAMLValue?, in text: String) throws -> String {
        precondition(!path.isEmpty)
        let endsWithNewline = text.isEmpty || text.hasSuffix("\n")
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast() }
        if text.isEmpty { lines = [] }

        try set(path, value, in: &lines)
        return lines.joined(separator: "\n") + (endsWithNewline && !lines.isEmpty ? "\n" : "")
    }

    /// Reads the value at `path`, or nil when it is missing or the text is not valid YAML.
    public static func value(at path: [String], in text: String) -> YAMLValue? {
        guard var node = try? Yams.compose(yaml: text) else { return nil }
        for key in path {
            guard let child = node[key] else { return nil }
            node = child
        }
        return YAMLValue(node: node)
    }

    // MARK: Editing lines

    /// The lines of a mapping: its body range and the indentation of its keys.
    private struct Block {
        var body: Range<Int>
        var indent: Int
        /// The line of the key that owns this mapping; nil for the document.
        var keyLine: Int?
    }

    private static func set(_ path: [String], _ value: YAMLValue?, in lines: inout [String]) throws {
        var block = Block(body: 0..<lines.count, indent: 0, keyLine: nil)
        var parents: [Block] = []
        for (depth, key) in path.enumerated() {
            let isLast = depth == path.count - 1
            guard let keyLine = find(key, in: block, lines: lines) else {
                guard let value else { return }
                let nested = path[(depth + 1)...].reversed().reduce(value) { .map([YAMLPair($1, $0)]) }
                insert(key, nested, into: block, path: Array(path[..<depth]), lines: &lines)
                return
            }
            let end = blockEnd(of: keyLine, lines: lines)
            if isLast {
                if let value {
                    let comment = trailingComment(lines[keyLine])
                    var rendered = render(key, value, indent: String(repeating: " ", count: block.indent))
                    if let comment, rendered.count == 1 { rendered[0] += comment }
                    lines.replaceSubrange(keyLine..<end, with: rendered)
                } else {
                    lines.removeSubrange(keyLine..<end)
                    removeEmptyParents(parents + [block], lines: &lines)
                }
                return
            }
            if let info = TOCWriter.keyInfo(lines[keyLine]), info.hasValue {
                let inline = inlineValue(lines[keyLine])
                guard ["null", "~", "{}", "false", "true"].contains(inline) else {
                    throw YAMLEditorError.inlineMapping(path[...depth].joined(separator: "."))
                }
                guard value != nil else { return }
                // `numbering: false` or `site: {}` becomes a block mapping.
                let nested = path[(depth + 1)...].reversed().reduce(value!) { .map([YAMLPair($1, $0)]) }
                let comment = trailingComment(lines[keyLine])
                var rendered = render(key, nested, indent: String(repeating: " ", count: block.indent))
                if let comment { rendered[0] += comment }
                lines.replaceSubrange(keyLine..<end, with: rendered)
                return
            }
            parents.append(block)
            let body = (keyLine + 1)..<end
            let indent = body.first(where: { !TOCWriter.isBlankOrComment(lines[$0]) }).map { TOCWriter.indentation(lines[$0]) }
                ?? block.indent + 2
            block = Block(body: body, indent: indent, keyLine: keyLine)
        }
    }

    /// The line of `key` directly in `block`, if any.
    private static func find(_ key: String, in block: Block, lines: [String]) -> Int? {
        block.body.first { i in
            !TOCWriter.isBlankOrComment(lines[i]) && TOCWriter.indentation(lines[i]) == block.indent
                && TOCWriter.keyInfo(lines[i]).map { unquoted($0.key) } == key
        }
    }

    /// The line after the block of the key at `keyLine`: deeper-indented lines, or list items
    /// at the key's own column. Trailing blank lines and comments are not part of it.
    private static func blockEnd(of keyLine: Int, lines: [String]) -> Int {
        let keyIndent = TOCWriter.indentation(lines[keyLine])
        var last = keyLine
        var i = keyLine + 1
        while i < lines.count {
            let line = lines[i]
            if TOCWriter.isBlankOrComment(line) {
                i += 1
                continue
            }
            let indent = TOCWriter.indentation(line)
            let sameColumnItem = indent == keyIndent && line.dropFirst(indent).hasPrefix("-")
            guard indent > keyIndent || sameColumnItem else { break }
            last = i
            i += 1
        }
        return last + 1
    }

    private static func insert(_ key: String, _ value: YAMLValue, into block: Block, path: [String], lines: inout [String]) {
        let rendered = render(key, value, indent: String(repeating: " ", count: block.indent))
        var at: Int
        if path == ["project"], let toc = find("toc", in: block, lines: lines) {
            at = toc
            // Keep comments written above `toc:` with it.
            while at > block.body.lowerBound, lines[at - 1].trimmingCharacters(in: .whitespaces).hasPrefix("#") { at -= 1 }
        } else if let last = block.body.last(where: { !TOCWriter.isBlankOrComment(lines[$0]) }) {
            at = last + 1
        } else {
            at = (block.keyLine.map { $0 + 1 }) ?? lines.count
        }
        lines.insert(contentsOf: rendered, at: at)
    }

    /// Removes mappings that a removal left without keys, innermost first.
    private static func removeEmptyParents(_ blocks: [Block], lines: inout [String]) {
        for block in blocks.reversed() {
            guard let keyLine = block.keyLine else { return }
            let end = blockEnd(of: keyLine, lines: lines)
            guard end == keyLine + 1 else { return }
            lines.remove(at: keyLine)
        }
    }

    // MARK: Rendering

    /// Renders `key: value` as block YAML lines.
    public static func render(_ key: String, _ value: YAMLValue, indent: String) -> [String] {
        let head = indent + quotedKey(key) + ":"
        switch value {
        case .string(let s): return [head + " " + scalar(s)]
        case .plain(let s): return [head + " " + s]
        case .list(let items):
            guard !items.isEmpty else { return [head + " []"] }
            return [head] + items.flatMap { renderItem($0, indent: indent + "  ") }
        case .map(let pairs):
            guard !pairs.isEmpty else { return [head + " {}"] }
            return [head] + pairs.flatMap { render($0.key, $0.value, indent: indent + "  ") }
        }
    }

    private static func renderItem(_ value: YAMLValue, indent: String) -> [String] {
        switch value {
        case .string(let s): return [indent + "- " + scalar(s)]
        case .plain(let s): return [indent + "- " + s]
        case .list(let items):
            guard !items.isEmpty else { return [indent + "- []"] }
            let inner = items.flatMap { renderItem($0, indent: indent + "  ") }
            return [indent + "-"] + inner
        case .map(let pairs):
            guard !pairs.isEmpty else { return [indent + "- {}"] }
            let inner = pairs.flatMap { render($0.key, $0.value, indent: indent + "  ") }
            return [indent + "- " + inner[0].dropFirst(indent.count + 2)] + inner.dropFirst()
        }
    }

    /// A string scalar: plain when unambiguous, otherwise single-quoted (so `\mathbb{R}` reads
    /// as written), double-quoted when it contains a quote or a line break.
    static func scalar(_ value: String) -> String {
        let plain = TOCWriter.scalar(value)
        guard plain.hasPrefix("\""), !value.contains("'"), !value.contains("\n"), !value.contains("\t") else { return plain }
        return "'" + value + "'"
    }

    static func quotedKey(_ key: String) -> String {
        let simple = !key.isEmpty && key.allSatisfy { $0.isLetter || $0.isNumber || "_-.".contains($0) }
        return simple ? key : scalar(key)
    }

    // MARK: Line helpers

    private static func unquoted(_ key: String) -> String {
        if key.count >= 2, let first = key.first, first == key.last, first == "'" || first == "\"" {
            return String(key.dropFirst().dropLast())
        }
        return key
    }

    /// The value written after `key:` on the line, without a trailing comment.
    private static func inlineValue(_ line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        var rest = String(line[line.index(after: colon)...])
        if let comment = rest.range(of: " #") { rest = String(rest[..<comment.lowerBound]) }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    /// A `# comment` at the end of a key line, with the spaces before it, kept when the value on that line is replaced.
    private static func trailingComment(_ line: String) -> String? {
        var inSingle = false, inDouble = false
        var previous: Character = " "
        for (offset, c) in line.enumerated() {
            if c == "'" && !inDouble { inSingle.toggle() }
            if c == "\"" && !inSingle { inDouble.toggle() }
            if c == "#" && !inSingle && !inDouble && previous == " " {
                // With the spaces before it, so the line keeps its alignment.
                let spaces = line.prefix(offset).reversed().prefix(while: { $0 == " " }).count
                return String(line.dropFirst(offset - spaces))
            }
            previous = c
        }
        return nil
    }
}
