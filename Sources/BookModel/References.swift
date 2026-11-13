import Foundation

/// Finds and rewrites file references in MyST Markdown: inline links and images `[text](target)`,
/// reference definitions `[label]: target`, and path arguments of directives such as `{include}`.
/// Code (fenced blocks, code directives and inline code) is left alone.
enum LinkRewriter {
    static let pathDirectives: Set<String> = ["include", "literalinclude", "figure", "image"]
    static let codeDirectives: Set<String> = ["code", "code-block", "code-cell", "sourcecode"]

    /// Returns `text` with every reference target replaced by `transform(target)`, where that is non-nil.
    static func rewrite(_ text: String, _ transform: (String) -> String?) -> String {
        var fences: [(char: Character, length: Int, isCode: Bool)] = []
        var output: [String] = []
        for line in text.components(separatedBy: "\n") {
            if let fence = fenceInfo(line) {
                if let top = fences.last, fence.info.isEmpty, fence.char == top.char, fence.length >= top.length {
                    fences.removeLast()
                    output.append(line)
                    continue
                }
                if fences.last?.isCode != true {
                    let directive = directiveName(fence.info)
                    let isCode = directive.map(codeDirectives.contains) ?? true
                    // A colon line without a directive is not a fence in MyST.
                    if fence.char != ":" || directive != nil {
                        fences.append((fence.char, fence.length, isCode))
                        if let directive, pathDirectives.contains(directive) {
                            output.append(rewriteDirectiveArgument(line, transform))
                        } else {
                            output.append(line)
                        }
                        continue
                    }
                }
            }
            if fences.last?.isCode == true {
                output.append(line)
                continue
            }
            output.append(rewriteInline(rewriteDefinition(line, transform), transform))
        }
        return output.joined(separator: "\n")
    }

    /// Every target `rewrite` would offer to `transform`.
    static func targets(in text: String) -> [String] {
        var found: [String] = []
        _ = rewrite(text) { found.append($0); return nil }
        return found
    }

    // MARK: Line parsing

    /// A fence opener or closer: three or more backticks, tildes or colons, then optional info.
    private static func fenceInfo(_ line: String) -> (char: Character, length: Int, info: String)? {
        let trimmed = line.drop(while: { $0 == " " })
        guard line.count - trimmed.count <= 3, let first = trimmed.first, "`~:".contains(first) else { return nil }
        let run = trimmed.prefix(while: { $0 == first })
        guard run.count >= 3 else { return nil }
        let info = trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
        return (first, run.count, info)
    }

    /// `{include} path` → "include".
    private static func directiveName(_ info: String) -> String? {
        guard info.hasPrefix("{"), let close = info.firstIndex(of: "}") else { return nil }
        return String(info[info.index(after: info.startIndex)..<close])
    }

    private static func rewriteDirectiveArgument(_ line: String, _ transform: (String) -> String?) -> String {
        guard let close = line.firstIndex(of: "}") else { return line }
        let rest = line[line.index(after: close)...]
        let argument = rest.trimmingCharacters(in: .whitespaces)
        guard !argument.isEmpty, let replacement = transform(argument),
              let range = rest.range(of: argument) else { return line }
        return line.replacingCharacters(in: range, with: replacement)
    }

    /// `[label]: target "title"`.
    private static func rewriteDefinition(_ line: String, _ transform: (String) -> String?) -> String {
        guard let match = line.range(of: #"^ {0,3}\[[^\]]+\]:[ \t]*"#, options: .regularExpression) else { return line }
        let rest = line[match.upperBound...]
        let target = rest.prefix(while: { !$0.isWhitespace })
        guard !target.isEmpty, let replacement = transform(String(target)) else { return line }
        return line.replacingCharacters(in: match.upperBound..<target.endIndex, with: replacement)
    }

    /// `[text](target)` and `![alt](target "title")`, skipping inline code spans.
    private static func rewriteInline(_ line: String, _ transform: (String) -> String?) -> String {
        let chars = Array(line)
        var result = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "`" {
                let run = chars[i...].prefix(while: { $0 == "`" }).count
                if let end = closingBackticks(chars, from: i + run, length: run) {
                    result += String(chars[i..<end + run])
                    i = end + run
                } else {
                    result += String(chars[i..<i + run])
                    i += run
                }
                continue
            }
            if c == "]", i + 1 < chars.count, chars[i + 1] == "(" {
                result += "]("
                var j = i + 2
                let angled = j < chars.count && chars[j] == "<"
                if angled { j += 1 }
                let start = j
                while j < chars.count, angled ? chars[j] != ">" : !(chars[j].isWhitespace || chars[j] == ")") {
                    j += 1
                }
                let target = String(chars[start..<j])
                if angled { result += "<" }
                result += (target.isEmpty ? nil : transform(target)) ?? target
                i = j
                continue
            }
            result.append(c)
            i += 1
        }
        return result
    }

    private static func closingBackticks(_ chars: [Character], from start: Int, length: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == "`" {
                let run = chars[i...].prefix(while: { $0 == "`" }).count
                if run == length { return i }
                i += run
            } else {
                i += 1
            }
        }
        return nil
    }
}

extension BookProject {
    /// How `page` refers to the project file `path`: relative to the page's folder.
    public static func reference(to path: String, from page: String) -> String {
        ProjectPath.relative(path, fromDirectory: ProjectPath.directory(of: page))
    }
}

/// Paths inside the project are relative to its root, with `/` separators.
enum ProjectPath {
    /// The project-relative path a reference in `page` points to, or nil for URLs, anchors and paths outside the project.
    static func resolve(_ target: String, from page: String) -> String? {
        let path = String(target.prefix(while: { $0 != "#" && $0 != "?" }))
        guard !path.isEmpty, !path.contains("://"), !path.hasPrefix("mailto:") else { return nil }
        let base: [String] = path.hasPrefix("/") ? [] : directory(of: page)
        return normalize(base + path.split(separator: "/").map(String.init))
    }

    static func directory(of path: String) -> [String] {
        Array(path.split(separator: "/").map(String.init).dropLast())
    }

    /// Resolves `.` and `..`; nil when the path leaves the project.
    static func normalize(_ components: [String]) -> String? {
        var stack: [String] = []
        for component in components where component != "." && !component.isEmpty {
            if component == ".." {
                guard !stack.isEmpty else { return nil }
                stack.removeLast()
            } else {
                stack.append(component)
            }
        }
        return stack.isEmpty ? nil : stack.joined(separator: "/")
    }

    /// `path` written relative to the folder `fromDirectory`.
    static func relative(_ path: String, fromDirectory: [String]) -> String {
        let target = path.split(separator: "/").map(String.init)
        var common = 0
        while common < fromDirectory.count, common < target.count - 1, fromDirectory[common] == target[common] {
            common += 1
        }
        let ups = Array(repeating: "..", count: fromDirectory.count - common)
        return (ups + target[common...]).joined(separator: "/")
    }

    /// A new reference to `path` from `page`, written in the style of `original`
    /// (absolute or relative, `./` prefix, with or without `.md`, anchor kept).
    static func reference(to path: String, from page: String, like original: String) -> String {
        let anchorStart = original.firstIndex(where: { $0 == "#" || $0 == "?" })
        let anchor = anchorStart.map { String(original[$0...]) } ?? ""
        let originalPath = anchorStart.map { String(original[..<$0]) } ?? original
        var written: String
        if originalPath.hasPrefix("/") {
            written = "/" + path
        } else {
            written = relative(path, fromDirectory: directory(of: page))
            if originalPath.hasPrefix("./") && !written.hasPrefix("../") { written = "./" + written }
        }
        if URL(fileURLWithPath: originalPath).pathExtension.isEmpty, written.hasSuffix(".md") {
            written.removeLast(3)
        }
        return written + anchor
    }
}
