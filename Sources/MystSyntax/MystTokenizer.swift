import Foundation

/// A line-based scanner for MyST Markdown. Block structure (front matter, fences, directives,
/// display math) is tracked across lines; prose lines are scanned for inline syntax.
/// It is fast enough to rescan a whole chapter on every keystroke.
public enum MystTokenizer {
    public static func tokens(in text: String) -> [MystToken] {
        var scanner = LineScanner(text: text as NSString)
        scanner.run()
        return scanner.tokens
    }
}

private struct LineScanner {
    enum Body { case markdown, code, math }

    struct Fence {
        var char: Character
        var length: Int
        var body: Body
        var isDirective: Bool
    }

    let ns: NSString
    var tokens: [MystToken] = []
    var fences: [Fence] = []
    /// After a directive opener: `:key: value` lines, or a `---` YAML block.
    var expectingOptions = false
    var optionsFirstLine = false
    var inYAMLOptions = false
    var inDisplayMath = false
    var inHTMLComment = false

    init(text: NSString) {
        ns = text
    }

    mutating func run() {
        var start = scanFrontMatter()
        while start < ns.length {
            var end = 0
            var contentsEnd = 0
            ns.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
            process(NSRange(location: start, length: contentsEnd - start))
            start = end
        }
    }

    /// `---` on the first line up to the next `---` line. Returns where the body starts.
    mutating func scanFrontMatter() -> Int {
        guard ns.length >= 3, ns.substring(to: 3) == "---" else { return 0 }
        var start = 0
        var first = true
        while start < ns.length {
            var end = 0
            var contentsEnd = 0
            ns.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
            let line = ns.substring(with: NSRange(location: start, length: contentsEnd - start)).trimmingCharacters(in: .whitespaces)
            if first {
                guard line == "---" else { return 0 }
                first = false
            } else if line == "---" {
                add(.frontMatter, NSRange(location: 0, length: contentsEnd))
                return end
            }
            start = end
        }
        return 0 // unterminated: treat as ordinary text
    }

    mutating func add(_ kind: MystToken.Kind, _ range: NSRange) {
        guard range.length > 0 else { return }
        tokens.append(MystToken(kind, range))
    }

    // MARK: Blocks

    mutating func process(_ line: NSRange) {
        let text = ns.substring(with: line)
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        if inHTMLComment {
            add(.comment, line)
            if text.contains("-->") { inHTMLComment = false }
            return
        }
        if inDisplayMath {
            if trimmed.hasSuffix("$$") {
                let dollar = ns.range(of: "$$", options: .backwards, range: line)
                add(.math, NSRange(location: line.location, length: dollar.location - line.location))
                add(.mathDelimiter, dollar)
                inDisplayMath = false
            } else {
                add(.math, line)
            }
            return
        }
        if inYAMLOptions {
            if trimmed == "---" {
                add(.directiveFence, line)
                inYAMLOptions = false
            } else {
                option(line, text: text, colonPrefixed: false)
            }
            return
        }
        if expectingOptions {
            if optionsFirstLine && trimmed == "---" {
                add(.directiveFence, line)
                inYAMLOptions = true
                expectingOptions = false
                return
            }
            optionsFirstLine = false
            if trimmed.hasPrefix(":"), option(line, text: text, colonPrefixed: true) { return }
            expectingOptions = false
        }

        if let fence = fenceInfo(text) {
            let marker = NSRange(location: line.location + fence.indent, length: fence.length)
            if let top = fences.last, fence.info.isEmpty, fence.char == top.char, fence.length >= top.length {
                fences.removeLast()
                add(top.isDirective ? .directiveFence : .codeFence, marker)
                return
            }
            if fences.last.map({ $0.body == .markdown }) ?? true {
                if let name = directiveName(fence.info) {
                    let body: Body = MystDirectives.code.contains(name) ? .code : MystDirectives.math.contains(name) ? .math : .markdown
                    fences.append(Fence(char: fence.char, length: fence.length, body: body, isDirective: true))
                    add(.directiveFence, marker)
                    let nameRange = ns.range(of: "{\(name)}", range: line)
                    add(.directiveName(name), nameRange)
                    let argStart = nameRange.location + nameRange.length
                    let argument = NSRange(location: argStart, length: line.location + line.length - argStart)
                    add(.directiveArgument(prose: !MystDirectives.nonProseArgument.contains(name)), trimmingSpaces(argument))
                    expectingOptions = true
                    optionsFirstLine = true
                    return
                }
                if fence.char != ":" {
                    fences.append(Fence(char: fence.char, length: fence.length, body: .code, isDirective: false))
                    add(.codeFence, NSRange(location: marker.location, length: line.location + line.length - marker.location))
                    return
                }
            }
        }
        switch fences.last?.body {
        case .code?: add(.code, line)
        case .math?: add(.math, line)
        default: markdown(line, text: text)
        }
    }

    /// `:key: value` (or `key: value` in a YAML options block). Returns false if the line is not an option.
    @discardableResult
    mutating func option(_ line: NSRange, text: String, colonPrefixed: Bool) -> Bool {
        let pattern = colonPrefixed ? #"^(\s*:[\w.-]+:)(.*)$"# : #"^(\s*[\w.-]+:)(.*)$"#
        guard let match = firstMatch(pattern, in: line) else {
            if !colonPrefixed { add(.directiveOptionValue, line) }
            return false
        }
        add(.directiveOptionKey, trimmingSpaces(match.range(at: 1)))
        add(.directiveOptionValue, trimmingSpaces(match.range(at: 2)))
        return true
    }

    mutating func markdown(_ line: NSRange, text: String) {
        if let match = firstMatch(#"^ {0,3}(\$\$)(.*)$"#, in: line) {
            add(.mathDelimiter, match.range(at: 1))
            let rest = match.range(at: 2)
            let restText = ns.substring(with: rest)
            if restText.trimmingCharacters(in: .whitespaces).hasSuffix("$$") {
                let close = ns.range(of: "$$", options: .backwards, range: rest)
                add(.math, NSRange(location: rest.location, length: close.location - rest.location))
                add(.mathDelimiter, close)
            } else {
                add(.math, rest)
                inDisplayMath = true
            }
            return
        }
        if let match = firstMatch(#"^ {0,3}(#{1,6})(?:[ \t]+|$)"#, in: line) {
            let marker = match.range(at: 1)
            add(.heading(level: marker.length), line)
            add(.headingMarker, marker)
            let restStart = match.range.location + match.range.length
            inline(NSRange(location: restStart, length: line.location + line.length - restStart))
            return
        }
        if firstMatch(#"^\s*\([^()\s]+\)=\s*$"#, in: line) != nil {
            add(.target, trimmingSpaces(line))
            return
        }
        if firstMatch(#"^\s*%"#, in: line) != nil {
            add(.comment, line)
            return
        }
        if firstMatch(#"^\s*<!--"#, in: line) != nil {
            add(.comment, line)
            if !text.contains("-->") { inHTMLComment = true }
            return
        }
        var rest = line
        if let match = firstMatch(#"^ {0,3}(?:>[ ]?)+"#, in: line) {
            add(.blockquoteMarker, match.range)
            rest = after(match.range, in: line)
        }
        if let match = firstMatch(#"^\s*(?:[-*+]|\d{1,9}[.)])(?=[ \t])"#, in: rest),
           firstMatch(#"^\s*([-*_])(\s*\1){2,}\s*$"#, in: line) == nil { // not a thematic break
            add(.listMarker, trimmingSpaces(match.range))
            rest = after(match.range, in: rest)
        } else if let match = firstMatch(#"^\[\^[^\]\s]+\]:"#, in: rest) {
            add(.footnote, match.range)
            rest = after(match.range, in: rest)
        }
        inline(rest)
    }

    // MARK: Inline

    mutating func inline(_ range: NSRange) {
        guard range.length > 0 else { return }
        var taken: [NSRange] = []
        func isFree(_ r: NSRange) -> Bool { !taken.contains { NSIntersectionRange($0, r).length > 0 } }

        // Backtick runs from left to right, as Markdown reads them: a run right after `{name}` opens
        // a role's content, any other run a code span; both end at the next run of the same length.
        // So `{x}` inside code (`\usepackage{inputenc}`) is code, not a role.
        let end = NSMaxRange(range)
        var i = range.location
        while i < end {
            guard ns.character(at: i) == 96 else { i += 1; continue }
            var runEnd = i
            while runEnd < end, ns.character(at: runEnd) == 96 { runEnd += 1 }
            // An escaped backtick (\`) is text.
            if i > range.location, ns.character(at: i - 1) == 92 { i = runEnd; continue }
            var close: Int?
            var j = runEnd
            while j < end {
                guard ns.character(at: j) == 96 else { j += 1; continue }
                var k = j
                while k < end, ns.character(at: k) == 96 { k += 1 }
                if k - j == runEnd - i { close = j; break }
                j = k
            }
            guard let close, close > runEnd else { i = runEnd; continue }
            let spanEnd = close + (runEnd - i)
            if let name = roleName(before: i, in: range) {
                let nameRange = NSRange(location: i - (name as NSString).length - 2, length: (name as NSString).length + 2)
                add(.roleName(name), nameRange)
                add(.roleContent, NSRange(location: i, length: spanEnd - i))
                taken.append(NSRange(location: nameRange.location, length: spanEnd - nameRange.location))
            } else {
                add(.inlineCode, NSRange(location: i, length: spanEnd - i))
                taken.append(NSRange(location: i, length: spanEnd - i))
            }
            i = spanEnd
        }
        for match in matches(#"(?<![\\$])\$(?=[^\s$])[^$\n]*?(?<=[^\s\\])\$(?![$\d])"#, in: range) where isFree(match.range) {
            add(.math, match.range)
            taken.append(match.range)
        }
        for (pattern, kind) in [(#"\{\{[^}\n]*\}\}"#, MystToken.Kind.substitution),
                                (#"<https?://[^>\s]+>|https?://[^\s)>\]]+"#, .url),
                                (#"\[\^[^\]\s]+\]"#, .footnote)] {
            for match in matches(pattern, in: range) where isFree(match.range) {
                add(kind, match.range)
                taken.append(match.range)
            }
        }
        for match in matches(#"!?\[([^\]\n]*)\]\(([^)\n]*)\)"#, in: range) where isFree(match.range) {
            add(.linkText, match.range(at: 1))
            add(.linkTarget, match.range(at: 2))
            taken.append(match.range(at: 2))
        }
        for match in matches(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, in: range) where isFree(match.range) {
            add(.strong, match.range)
        }
        let emphasis = #"(?<![*\w\\])\*(?=[^\s*])(.+?)(?<=[^\s*\\])\*(?![*\w])|(?<![_\w\\])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![_\w])"#
        for match in matches(emphasis, in: range) where isFree(match.range) {
            add(.emphasis, match.range)
        }
    }

    // MARK: Helpers

    /// The role name in `{name}` ending right before `location`, if there is one.
    func roleName(before location: Int, in range: NSRange) -> String? {
        guard location - 3 >= range.location, ns.character(at: location - 1) == 125 else { return nil }
        var open = location - 2
        while open >= range.location, ns.character(at: open) != 123 {
            guard location - open < 64 else { return nil }
            open -= 1
        }
        guard open >= range.location else { return nil }
        let name = ns.substring(with: NSRange(location: open + 1, length: location - 2 - open))
        return name.range(of: #"^[A-Za-z][\w:.-]*$"#, options: .regularExpression) != nil ? name : nil
    }

    func fenceInfo(_ line: String) -> (char: Character, length: Int, indent: Int, info: String)? {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard let first = rest.first, "`~:".contains(first) else { return nil }
        let run = rest.prefix(while: { $0 == first }).count
        guard run >= 3 else { return nil }
        let info = rest.dropFirst(run).trimmingCharacters(in: .whitespaces)
        // A backtick fence's info string may not contain backticks.
        if first == "`" && info.contains("`") { return nil }
        // Fences are ASCII, so character counts equal UTF-16 counts here.
        return (first, run, indent, info)
    }

    func directiveName(_ info: String) -> String? {
        guard info.hasPrefix("{"), let close = info.firstIndex(of: "}") else { return nil }
        let name = String(info[info.index(after: info.startIndex)..<close])
        return name.isEmpty ? nil : name
    }

    func after(_ prefix: NSRange, in range: NSRange) -> NSRange {
        let start = prefix.location + prefix.length
        return NSRange(location: start, length: range.location + range.length - start)
    }

    func trimmingSpaces(_ range: NSRange) -> NSRange {
        guard range.location != NSNotFound else { return NSRange(location: 0, length: 0) }
        var start = range.location
        var end = range.location + range.length
        while start < end, isSpace(ns.character(at: start)) { start += 1 }
        while end > start, isSpace(ns.character(at: end - 1)) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    func isSpace(_ c: unichar) -> Bool { c == 32 || c == 9 }

    func firstMatch(_ pattern: String, in range: NSRange) -> NSTextCheckingResult? {
        Regex.cached(pattern).firstMatch(in: ns as String, options: [], range: range)
    }

    func matches(_ pattern: String, in range: NSRange) -> [NSTextCheckingResult] {
        Regex.cached(pattern).matches(in: ns as String, options: [], range: range)
    }
}

/// Compiled regular expressions, shared across scans.
enum Regex {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: NSRegularExpression] = [:]

    static func cached(_ pattern: String) -> NSRegularExpression {
        lock.lock()
        defer { lock.unlock() }
        if let regex = cache[pattern] { return regex }
        // Patterns are literals in this file, so failing to compile is a programming error.
        let regex = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        cache[pattern] = regex
        return regex
    }
}
