import Foundation

/// One problem reported by a build, linked to a page and line when the tool says which.
public struct BuildMessage: Identifiable, Hashable, Sendable {
    public enum Severity: String, Hashable, Sendable {
        case error, warning
    }

    public var id: Int
    public var severity: Severity
    /// Relative to the project folder, as the tool prints it.
    public var file: String?
    public var line: Int?
    public var column: Int?
    public var text: String
    /// Indented lines the tool prints under a message, such as the offending source.
    public var detail: [String]
}

/// Turns `myst` / `jupyter-book` output into messages. Lines look like
/// `⛔️ page.md:8 Undefined control sequence …` or `⚠️  page.md Could not link citation …`.
public struct BuildLogParser: Sendable {
    public private(set) var messages: [BuildMessage] = []
    private var lastWasMessage = false
    private var seen = Set<String>()

    public init() {}

    public mutating func consume(_ rawLine: String) {
        let line = Self.strippingANSI(rawLine)
        guard let first = line.unicodeScalars.first else {
            lastWasMessage = false
            return
        }
        let severity: BuildMessage.Severity?
        switch first {
        case "\u{26D4}", "\u{274C}", "\u{1F6AB}": severity = .error   // ⛔ ❌ 🚫
        case "\u{26A0}": severity = .warning                          // ⚠
        default: severity = nil
        }
        guard let severity else {
            // The tool indents the source line it complains about under the message.
            if lastWasMessage, line.hasPrefix("  "), !line.trimmingCharacters(in: .whitespaces).isEmpty,
               messages[messages.count - 1].detail.count < 5 {
                messages[messages.count - 1].detail.append(line.trimmingCharacters(in: .whitespaces))
            } else {
                lastWasMessage = false
            }
            return
        }
        // Drop the symbol (plus any variation selector) and the spaces after it.
        let body = String(String.UnicodeScalarView(line.unicodeScalars.dropFirst().drop { $0 == "\u{FE0F}" }))
            .trimmingCharacters(in: .whitespaces)
        var message = BuildMessage(id: messages.count, severity: severity, file: nil, line: nil, column: nil, text: body, detail: [])
        let pattern = #"^(\S+\.(?:md|ipynb|myst|ya?ml|bib|tex|tsx?|mjs|js))(?::(\d+))?(?::(\d+))?:?\s+(.*)$"#
        if let match = body.range(of: pattern, options: .regularExpression) {
            let groups = Self.groups(of: pattern, in: String(body[match]))
            message.file = groups[1]
            message.line = groups[2].flatMap { Int($0) }
            message.column = groups[3].flatMap { Int($0) }
            message.text = groups[4] ?? body
        }
        // The same problem is often printed twice, and again on every rebuild of the preview.
        let key = "\(message.severity)|\(message.file ?? "")|\(message.line ?? 0)|\(message.text)"
        guard seen.insert(key).inserted else {
            lastWasMessage = false
            return
        }
        messages.append(message)
        lastWasMessage = true
    }

    public var errorCount: Int { messages.filter { $0.severity == .error }.count }
    public var warningCount: Int { messages.filter { $0.severity == .warning }.count }

    static func strippingANSI(_ text: String) -> String {
        text.replacingOccurrences(of: #"\x{1B}\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
    }

    private static func groups(of pattern: String, in text: String) -> [String?] {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return [] }
        return (0..<match.numberOfRanges).map { i in
            Range(match.range(at: i), in: text).map { String(text[$0]) }
        }
    }
}
