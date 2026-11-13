import Foundation

/// What is being typed at the cursor, for completion: the kind of name and the range of the
/// partial name that a completion replaces.
public struct CompletionContext: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// After "```{" or ":::{".
        case directiveName
        /// After an inline "{".
        case roleName
        /// Inside `{ref}`, `{numref}` or `{eq}`.
        case label(role: String)
        /// Inside `{cite}` or after "@".
        case citation
        /// A path: a directive argument, `{doc}`, or a link target.
        case path(via: String)
        /// "#" in a link target.
        case linkAnchor
        /// ":" at the start of a line in a directive's option block.
        case directiveOption(directive: String, used: [String])
    }

    public var kind: Kind
    /// The partial name before the cursor (what the completion replaces).
    public var range: NSRange
    public var prefix: String

    /// The context at `cursor` in `text`, or nil when nothing completable is being typed.
    public static func at(_ cursor: Int, in text: String) -> CompletionContext? {
        let ns = text as NSString
        guard cursor >= 0, cursor <= ns.length else { return nil }
        let lineStart = ns.lineRange(for: NSRange(location: cursor, length: 0)).location
        let before = ns.substring(with: NSRange(location: lineStart, length: cursor - lineStart))

        func context(_ kind: Kind, _ partial: String) -> CompletionContext {
            let length = (partial as NSString).length
            return CompletionContext(kind: kind, range: NSRange(location: cursor - length, length: length), prefix: partial)
        }
        func match(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let result = regex.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) else { return nil }
            return (0..<result.numberOfRanges).map { i in
                let range = result.range(at: i)
                return range.location == NSNotFound ? "" : (before as NSString).substring(with: range)
            }
        }

        if let groups = match(#"^\s*(?:`{3,}|:{3,})\{([\w:.-]*)$"#) {
            return context(.directiveName, groups[1])
        }
        if let groups = match(#"^\s*(?:`{3,}|:{3,})\{([\w:.-]+)\}\s+(\S*)$"#), PageSymbols.pathDirectives.contains(groups[1]) {
            return context(.path(via: groups[1]), groups[2])
        }
        if let groups = match(#"\{([\w:.-]+)\}(`+)([^`]*)$"#) {
            let role = groups[1], content = groups[3]
            if MystCatalog.citationRoles.contains(role) {
                let partial = content.split(omittingEmptySubsequences: false, whereSeparator: { ",; ".contains($0) }).last.map(String.init) ?? ""
                return context(.citation, partial)
            }
            let target = content.range(of: "<", options: .backwards).map { String(content[$0.upperBound...]) } ?? content
            if MystCatalog.labelRoles.keys.contains(role) { return context(.label(role: role), target) }
            if role == "doc" { return context(.path(via: "doc"), target) }
            return nil
        }
        if let groups = match(#"(?:^|[^{\\])\{([\w:.-]*)$"#) {
            return context(.roleName, groups[1])
        }
        if let groups = match(#"\]\(#([^)\s]*)$"#) {
            return context(.linkAnchor, groups[1])
        }
        if let groups = match(#"\]\(([^)\s#]*)$"#) {
            return context(.path(via: "link"), groups[1])
        }
        if let groups = match(#"(?:^|[\s(\[;,])@([\w:.-]*)$"#) {
            return context(.citation, groups[1])
        }
        if let groups = match(#"^\s*:([\w-]*)$"#), let (directive, used) = optionBlock(endingAt: lineStart, in: ns) {
            return context(.directiveOption(directive: directive, used: used), groups[1])
        }
        return nil
    }

    /// If the lines above `lineStart` are a directive opener followed only by option lines,
    /// the directive's name and the options already given.
    private static func optionBlock(endingAt lineStart: Int, in ns: NSString) -> (String, [String])? {
        var used: [String] = []
        var end = lineStart
        while end > 0 {
            let range = ns.lineRange(for: NSRange(location: end - 1, length: 0))
            let line = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            if let option = line.range(of: #"^:([\w-]+):"#, options: .regularExpression) {
                used.append(String(line[option].dropFirst().dropLast()))
            } else if let opener = line.range(of: #"^(?:`{3,}|:{3,})\{([\w:.-]+)\}"#, options: .regularExpression) {
                let text = String(line[opener])
                let name = text.drop { $0 != "{" }.dropFirst().prefix { $0 != "}" }
                return (String(name), used)
            } else {
                return nil
            }
            end = range.location
        }
        return nil
    }
}
