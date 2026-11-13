import Foundation

/// A directive in a page (```` ```{name} argument ```` or `:::{name}` … closing fence), with its
/// `:key: value` options, for the inspector's form. Ranges are UTF-16 offsets in the page.
public struct DirectiveBlock: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public var key: String
        public var value: String
        /// The whole line, including its newline.
        public var line: NSRange
    }

    public var name: String
    public var argument: String
    public var options: [Option]
    /// The opening fence line, without its newline.
    public var openingLine: NSRange
    /// From the opening fence to the end of the closing fence (or of the page when unclosed).
    public var range: NSRange
    public var indent: String
    /// The fence as written (```` ``` ````, `:::`, `::::`, …).
    public var fence: String

    public func option(_ key: String) -> Option? {
        options.first { $0.key == key }
    }

    /// Where a new option line goes: after the last option, or right after the opening line.
    var optionInsertLocation: Int {
        options.last.map { NSMaxRange($0.line) } ?? NSMaxRange(openingLine)
    }

    /// `text` with option `key` set to `value` (`""` writes a flag like `:open:`), or removed when
    /// `value` is nil. A new option goes after the others.
    public func settingOption(_ key: String, to value: String?, in text: String) -> String {
        let ns = NSMutableString(string: text)
        let line = value.map { indent + ":\(key):" + ($0.isEmpty ? "" : " " + $0) + "\n" }
        if let existing = option(key) {
            ns.replaceCharacters(in: existing.line, with: line ?? "")
        } else if let line {
            var location = optionInsertLocation
            var insertion = line
            if options.isEmpty {
                // After the opening line's newline; a page that ends on the opening line gets one.
                if location < ns.length, ns.character(at: location) == 10 {
                    location += 1
                } else {
                    insertion = "\n" + String(line.dropLast())
                }
            }
            ns.insert(insertion, at: location)
        }
        return ns as String
    }

    /// `text` with the opening line's argument (what follows `{name}`) replaced.
    public func settingArgument(_ argument: String, in text: String) -> String {
        let trimmed = argument.trimmingCharacters(in: .whitespaces)
        let line = indent + fence + "{\(name)}" + (trimmed.isEmpty ? "" : " " + trimmed)
        return (text as NSString).replacingCharacters(in: openingLine, with: line)
    }
}

public enum DirectiveBlocks {
    /// Every directive in `text`, outer ones before the directives inside them.
    public static func all(in text: String) -> [DirectiveBlock] {
        let ns = text as NSString
        struct Open {
            var block: DirectiveBlock?
            var char: Character
            var length: Int
        }
        var stack: [Open] = []
        var found: [DirectiveBlock] = []
        var location = 0
        var lineIndex = 0
        var inFrontMatter = false
        var optionsOpen = false
        while location < ns.length {
            let full = ns.lineRange(for: NSRange(location: location, length: 0))
            var contentsEnd = 0
            ns.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: full)
            let lineRange = NSRange(location: full.location, length: contentsEnd - full.location)
            let line = ns.substring(with: lineRange)
            defer {
                location = NSMaxRange(full)
                lineIndex += 1
            }
            if lineIndex == 0, line == "---" { inFrontMatter = true; continue }
            if inFrontMatter {
                if line.trimmingCharacters(in: .whitespaces) == "---" { inFrontMatter = false }
                continue
            }
            if optionsOpen, let top = stack.last, var block = top.block,
               let option = parseOption(line) {
                block.options.append(DirectiveBlock.Option(key: option.key, value: option.value, line: full))
                stack[stack.count - 1].block = block
                continue
            }
            optionsOpen = false
            guard let fence = parseFence(line) else { continue }
            if let top = stack.last, fence.info.isEmpty, fence.char == top.char, fence.length >= top.length {
                let closed = stack.removeLast()
                if var block = closed.block {
                    block.range = NSRange(location: block.range.location, length: NSMaxRange(lineRange) - block.range.location)
                    found.append(block)
                }
                continue
            }
            // Inside plain code nothing opens.
            if let top = stack.last, top.block == nil { continue }
            if let (name, argument) = directive(fence.info) {
                let block = DirectiveBlock(name: name, argument: argument, options: [], openingLine: lineRange,
                                           range: NSRange(location: lineRange.location, length: 0),
                                           indent: String(line.prefix(fence.indent)),
                                           fence: String(repeating: fence.char, count: fence.length))
                stack.append(Open(block: block, char: fence.char, length: fence.length))
                optionsOpen = true
            } else if fence.char == "`" {
                stack.append(Open(block: nil, char: fence.char, length: fence.length))
            }
        }
        // Unclosed directives run to the end of the page.
        for open in stack.reversed() {
            if var block = open.block {
                block.range = NSRange(location: block.range.location, length: ns.length - block.range.location)
                found.append(block)
            }
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    /// The innermost directive whose fences enclose `location`.
    public static func innermost(at location: Int, in text: String) -> DirectiveBlock? {
        all(in: text).filter { $0.range.location <= location && location <= NSMaxRange($0.range) }
            .min { $0.range.length < $1.range.length }
    }

    static func parseFence(_ line: String) -> (char: Character, length: Int, indent: Int, info: String)? {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent < 4 else { return nil }
        let rest = line.dropFirst(indent)
        guard let char = rest.first, char == "`" || char == ":" else { return nil }
        let length = rest.prefix(while: { $0 == char }).count
        guard length >= 3 else { return nil }
        return (char, length, indent, rest.dropFirst(length).trimmingCharacters(in: .whitespaces))
    }

    static func directive(_ info: String) -> (String, String)? {
        guard info.hasPrefix("{"), let close = info.firstIndex(of: "}") else { return nil }
        let name = String(info[info.index(after: info.startIndex)..<close])
        guard !name.isEmpty, !name.contains(" ") else { return nil }
        return (name, info[info.index(after: close)...].trimmingCharacters(in: .whitespaces))
    }

    static func parseOption(_ line: String) -> (key: String, value: String)? {
        let trimmed = line.drop(while: { $0 == " " })
        guard trimmed.hasPrefix(":"), !trimmed.hasPrefix("::") else { return nil }
        let afterColon = trimmed.dropFirst()
        guard let end = afterColon.firstIndex(of: ":") else { return nil }
        let key = String(afterColon[..<end])
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return (key, afterColon[afterColon.index(after: end)...].trimmingCharacters(in: .whitespaces))
    }
}
