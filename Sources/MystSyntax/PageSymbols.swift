import Foundation

/// What a page defines and refers to: labels, references, used directives and roles, and files.
/// Ranges are UTF-16 based and point at the name itself (the label, key or path), lines are 1-based.
public struct PageSymbols: Equatable, Sendable {
    public struct Label: Equatable, Sendable {
        public var name: String
        public var kind: LabelKind
        /// The heading text, directive argument or page title, if any.
        public var title: String?
        public var range: NSRange
        public var line: Int
        /// The start of what the label points to: the first text after a heading, an equation's
        /// formula, a figure's caption. Shown when choosing a label.
        public var snippet: String?
    }

    public struct Reference: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// `{ref}`, `{numref}` or `{eq}`.
            case role(String)
            /// `[text](#label)`.
            case link
            case citation
        }

        public var kind: Kind
        public var target: String
        public var range: NSRange
        public var line: Int
    }

    public struct FileReference: Equatable, Sendable {
        /// As written, relative to the page (or to the project root with a leading "/").
        public var path: String
        /// "figure", "include", "link", "image", "doc", …
        public var via: String
        public var range: NSRange
        public var line: Int
    }

    public struct Usage: Equatable, Sendable {
        public var name: String
        public var range: NSRange
        public var line: Int
    }

    public var labels: [Label] = []
    public var references: [Reference] = []
    public var files: [FileReference] = []
    public var directives: [Usage] = []
    public var roles: [Usage] = []
    /// The ids MyST gives the page's headings (labels or derived from the text), for `#` links.
    public var headingAnchors: [String] = []
    /// Lines that look like a label written with braces, `{name}=`, which MyST does not read as a
    /// label (labels use parentheses: `(name)=`). The range covers `{name}=`.
    public var braceTargets: [Usage] = []

    public init() {}

    public static let pathDirectives: Set<String> = ["include", "literalinclude", "figure", "image"]

    public static func scan(_ text: String) -> PageSymbols {
        let ns = text as NSString
        let tokens = MystTokenizer.tokens(in: text)
        let lines = LineIndex(ns)
        var symbols = PageSymbols()
        let headings = MystOutline.headings(in: text, tokens: tokens)
        symbols.headingAnchors = HeadingAnchors.anchors(for: headings)

        // "{name}=" at the start of a line, outside code and math.
        let code = tokens.filter {
            switch $0.kind {
            case .code, .codeFence, .inlineCode, .math, .frontMatter, .comment: return true
            default: return false
            }
        }.map(\.range)
        let bracePattern = try! NSRegularExpression(pattern: #"^[ \t]*(\{([^{}\s`]+)\}=)"#, options: .anchorsMatchLines)
        for match in bracePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let range = match.range(at: 1)
            guard !code.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
            symbols.braceTargets.append(Usage(name: ns.substring(with: match.range(at: 2)), range: range, line: lines.line(at: range.location)))
        }

        var currentDirective: String?
        for (index, token) in tokens.enumerated() {
            let value = ns.substring(with: token.range)
            switch token.kind {
            case .frontMatter:
                symbols.scanFrontMatter(token.range, ns: ns, lines: lines)
            case .target:
                // "(name)=" — a label for the next heading, or for the block that follows.
                let nameRange = NSRange(location: token.range.location + 1, length: max(0, token.range.length - 3))
                let name = ns.substring(with: nameRange)
                let heading = headings.first { $0.range.location > token.range.location && $0.label == name }
                symbols.labels.append(Label(name: name, kind: heading == nil ? .target : .heading, title: heading?.title,
                                            range: nameRange, line: lines.line(at: nameRange.location)))
            case .directiveName(let name):
                currentDirective = name
                let nameRange = NSRange(location: token.range.location + 1, length: max(0, token.range.length - 2))
                symbols.directives.append(Usage(name: name, range: nameRange, line: lines.line(at: nameRange.location)))
            case .directiveArgument:
                if let directive = currentDirective, Self.pathDirectives.contains(directive) {
                    symbols.files.append(FileReference(path: value, via: directive, range: token.range, line: lines.line(at: token.range.location)))
                }
            case .directiveOptionKey:
                guard let directive = currentDirective, value == ":label:" || value == ":name:" || value == "label:",
                      index + 1 < tokens.count, tokens[index + 1].kind == .directiveOptionValue else { continue }
                let valueToken = tokens[index + 1]
                let argument = symbols.lastDirectiveArgument(tokens, before: index, ns: ns)
                symbols.labels.append(Label(name: ns.substring(with: valueToken.range), kind: .forDirective(directive),
                                            title: argument, range: valueToken.range, line: lines.line(at: valueToken.range.location)))
            case .roleName(let name):
                let nameRange = NSRange(location: token.range.location + 1, length: max(0, token.range.length - 2))
                symbols.roles.append(Usage(name: name, range: nameRange, line: lines.line(at: nameRange.location)))
                guard index + 1 < tokens.count, tokens[index + 1].kind == .roleContent else { continue }
                symbols.scanRoleContent(name, tokens[index + 1].range, ns: ns, lines: lines)
            case .linkTarget:
                symbols.scanLinkTarget(value, token.range, isImage: index > 0 && symbols.isImage(tokens[index - 1], ns: ns), lines: lines)
            default:
                break
            }
            // Options and the argument belong to the directive opened just before them.
            switch token.kind {
            case .directiveName, .directiveArgument, .directiveOptionKey, .directiveOptionValue, .directiveFence: break
            default: currentDirective = nil
            }
        }
        let allLines = text.components(separatedBy: "\n")
        for i in symbols.labels.indices {
            symbols.labels[i].snippet = Self.snippet(after: symbols.labels[i].line, in: allLines, skipHeading: symbols.labels[i].kind == .heading)
        }
        return symbols
    }

    /// The first line of content after `line` (1-based): skips blank lines, directive options,
    /// targets, fences and, for heading labels, the heading itself. At most about 140 characters.
    static func snippet(after line: Int, in lines: [String], skipHeading: Bool) -> String? {
        var skippedHeading = !skipHeading
        var index = line
        while index < lines.count {
            let text = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
            if text.isEmpty || text.hasPrefix(":") && text.dropFirst().first?.isLetter == true { continue }
            if text.range(of: #"^\([^()\s]+\)=$"#, options: .regularExpression) != nil { continue }
            if text.range(of: #"^(`{3,}|~{3,}|:{3,})"#, options: .regularExpression) != nil { return nil }
            if text.hasPrefix("#") {
                if !skippedHeading { skippedHeading = true; continue }
                return nil
            }
            if text == "---" { continue }
            // Math reads better without its dollar signs in a one-line preview.
            let plain = text.replacingOccurrences(of: "$", with: "")
            return plain.count > 140 ? String(plain.prefix(139)) + "…" : plain
        }
        return nil
    }

    private func lastDirectiveArgument(_ tokens: [MystToken], before index: Int, ns: NSString) -> String? {
        for token in tokens[..<index].reversed() {
            if case .directiveArgument = token.kind { return ns.substring(with: token.range) }
            if case .directiveName = token.kind { return nil }
        }
        return nil
    }

    private func isImage(_ previous: MystToken, ns: NSString) -> Bool {
        previous.kind == .linkText && previous.range.location >= 2 && ns.substring(with: NSRange(location: previous.range.location - 2, length: 1)) == "!"
    }

    private mutating func scanFrontMatter(_ range: NSRange, ns: NSString, lines: LineIndex) {
        let pattern = try! NSRegularExpression(pattern: #"^label:[ \t]*(\S+)[ \t]*$"#, options: .anchorsMatchLines)
        guard let match = pattern.firstMatch(in: ns as String, range: range) else { return }
        let nameRange = match.range(at: 1)
        let title = try! NSRegularExpression(pattern: #"^title:[ \t]*(.+?)[ \t]*$"#, options: .anchorsMatchLines)
            .firstMatch(in: ns as String, range: range).map { ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        labels.append(Label(name: ns.substring(with: nameRange), kind: .page, title: title, range: nameRange, line: lines.line(at: nameRange.location)))
    }

    /// The text between the backticks of a role: a label (optionally "text <label>"), citation
    /// keys separated by commas or semicolons, or a page for {doc}.
    private mutating func scanRoleContent(_ role: String, _ contentRange: NSRange, ns: NSString, lines: LineIndex) {
        let content = ns.substring(with: contentRange)
        let ticks = content.prefix(while: { $0 == "`" }).count
        guard content.count > ticks * 2 else { return }
        let inner = NSRange(location: contentRange.location + ticks, length: contentRange.length - ticks * 2)
        var target = inner
        let innerText = ns.substring(with: inner)
        if let open = innerText.range(of: "<", options: .backwards), innerText.hasSuffix(">") {
            let start = innerText.utf16.distance(from: innerText.utf16.startIndex, to: open.upperBound.samePosition(in: innerText.utf16)!)
            target = NSRange(location: inner.location + start, length: inner.length - start - 1)
        }
        if MystCatalog.labelRoles.keys.contains(role) {
            references.append(Reference(kind: .role(role), target: ns.substring(with: target), range: target, line: lines.line(at: target.location)))
        } else if MystCatalog.citationRoles.contains(role) {
            let pattern = try! NSRegularExpression(pattern: #"[^,;\s]+"#)
            for match in pattern.matches(in: ns as String, range: inner) {
                references.append(Reference(kind: .citation, target: ns.substring(with: match.range), range: match.range, line: lines.line(at: match.range.location)))
            }
        } else if role == "doc" {
            files.append(FileReference(path: ns.substring(with: target), via: "doc", range: target, line: lines.line(at: target.location)))
        }
    }

    private mutating func scanLinkTarget(_ value: String, _ range: NSRange, isImage: Bool, lines: LineIndex) {
        guard !value.isEmpty, !value.contains("://"), !value.hasPrefix("mailto:") else { return }
        if value.hasPrefix("#") {
            let label = NSRange(location: range.location + 1, length: range.length - 1)
            guard label.length > 0 else { return }
            references.append(Reference(kind: .link, target: String(value.dropFirst()), range: label, line: lines.line(at: label.location)))
            return
        }
        let path = String(value.prefix { $0 != "#" && $0 != "?" })
        // `xref:` and other schemes without "//" are not files.
        guard !path.isEmpty, path.range(of: #"^[A-Za-z][\w+.-]*:"#, options: .regularExpression) == nil else { return }
        let pathRange = NSRange(location: range.location, length: (path as NSString).length)
        files.append(FileReference(path: path, via: isImage ? "image" : "link", range: pathRange, line: lines.line(at: range.location)))
    }
}

/// 1-based line numbers for UTF-16 offsets.
struct LineIndex {
    private var starts: [Int] = [0]

    init(_ ns: NSString) {
        for i in 0..<ns.length where ns.character(at: i) == 10 { starts.append(i + 1) }
    }

    func line(at location: Int) -> Int {
        var low = 0, high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= location { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
