import Foundation

public enum TOCWriterError: LocalizedError, Equatable {
    /// `key` has an inline value (e.g. `toc: [...]`) that cannot be edited line by line.
    case unsupportedLayout(key: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedLayout(let key):
            return "myst.yml writes `\(key)` in a form the app cannot edit automatically. Please write it as a block (one entry per line)."
        }
    }
}

/// Writes the table of contents back into `myst.yml` as a minimal text edit:
/// only the `project.toc` block is replaced; every other line, including comments,
/// is kept byte for byte.
public enum TOCWriter {

    // MARK: Rendering

    /// Renders entries as YAML block-sequence lines, each prefixed with `indent`.
    public static func render(_ entries: [TOCEntry], indent: String) -> [String] {
        var lines: [String] = []
        for entry in entries {
            var fields: [String] = []
            switch entry.kind {
            case .file(let path): fields.append("file: " + scalar(path))
            case .pattern(let pattern): fields.append("pattern: " + scalar(pattern))
            case .url(let url): fields.append("url: " + scalar(url))
            case .group: break
            }
            if let title = entry.title ?? (entry.isGroup ? "Untitled part" : nil) {
                // A group's title comes first, so the part reads well in the YAML.
                if entry.isGroup {
                    fields.insert("title: " + scalar(title), at: 0)
                } else {
                    fields.append("title: " + scalar(title))
                }
            }
            if entry.hidden { fields.append("hidden: true") }
            if !entry.children.isEmpty {
                fields.append("children:")
            } else if entry.isGroup {
                fields.append("children: []")
            }
            for (i, field) in fields.enumerated() {
                lines.append(indent + (i == 0 ? "- " : "  ") + field)
            }
            if !entry.children.isEmpty {
                lines += render(entry.children, indent: indent + "    ")
            }
        }
        return lines
    }

    /// A YAML scalar, plain when that is unambiguous, otherwise double-quoted.
    static func scalar(_ value: String) -> String {
        let reserved: Set<String> = ["", "~", "null", "true", "false", "yes", "no", "on", "off"]
        let plainStart = value.first.map { $0.isLetter || $0.isNumber || "_./".contains($0) } ?? false
        let ambiguous = value.contains(": ") || value.contains(" #") || value.hasSuffix(":")
            || value.hasSuffix(" ") || value.contains("\n") || value.contains("\t") || value.contains("\"")
        if plainStart, !ambiguous, !reserved.contains(value.lowercased()), Double(value) == nil {
            return value
        }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"" + escaped + "\""
    }

    // MARK: Splicing

    /// Returns `text` with its `project.toc` block replaced by `entries`.
    /// Adds `toc:` (and `project:` if needed) when they are missing.
    public static func replacingTOC(in text: String, with entries: [TOCEntry]) throws -> String {
        let endsWithNewline = text.isEmpty || text.hasSuffix("\n")
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast() }
        if text.isEmpty { lines = [] }

        guard let projectLine = lines.firstIndex(where: { indentation($0) == 0 && keyInfo($0)?.key == "project" }) else {
            lines += ["project:", "  toc:"] + render(entries, indent: "    ")
            return join(lines, endsWithNewline: endsWithNewline)
        }
        if keyInfo(lines[projectLine])?.hasValue == true {
            throw TOCWriterError.unsupportedLayout(key: "project")
        }

        // The project block runs until the next top-level key.
        var projectEnd = projectLine + 1
        while projectEnd < lines.count {
            let line = lines[projectEnd]
            if !isBlankOrComment(line) && indentation(line) == 0 { break }
            projectEnd += 1
        }
        let body = (projectLine + 1)..<projectEnd
        let childIndent = body.first(where: { !isBlankOrComment(lines[$0]) }).map { indentation(lines[$0]) } ?? 2
        let keyIndent = String(repeating: " ", count: childIndent)
        let itemIndent = String(repeating: " ", count: childIndent + 2)
        let newBlock = [keyIndent + "toc:"] + render(entries, indent: itemIndent)

        if let tocLine = body.first(where: {
            !isBlankOrComment(lines[$0]) && indentation(lines[$0]) == childIndent && keyInfo(lines[$0])?.key == "toc"
        }) {
            if keyInfo(lines[tocLine])?.hasValue == true {
                throw TOCWriterError.unsupportedLayout(key: "project.toc")
            }
            // The toc block: deeper-indented lines, or list items at the key's own indentation
            // (YAML allows `toc:` followed by `- file: ...` at the same column).
            var lastBlockLine = tocLine
            var i = tocLine + 1
            while i < projectEnd {
                let line = lines[i]
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    i += 1
                    continue
                }
                let indent = indentation(line)
                let isSameColumnItem = indent == childIndent && line.dropFirst(indent).hasPrefix("-")
                guard indent > childIndent || isSameColumnItem else { break }
                lastBlockLine = i
                i += 1
            }
            lines.replaceSubrange(tocLine...lastBlockLine, with: newBlock)
        } else {
            let lastContent = body.last(where: { !isBlankOrComment(lines[$0]) }) ?? projectLine
            lines.insert(contentsOf: newBlock, at: lastContent + 1)
        }
        return join(lines, endsWithNewline: endsWithNewline)
    }

    // MARK: Line helpers

    static func indentation(_ line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    static func isBlankOrComment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("#")
    }

    /// For a line like `  toc:  # comment` returns ("toc", hasValue: false);
    /// for `title: My Book` returns ("title", hasValue: true); nil if the line is not a `key:` line.
    static func keyInfo(_ line: String) -> (key: String, hasValue: Bool)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("-"), !trimmed.hasPrefix("#"), let colon = trimmed.firstIndex(of: ":") else { return nil }
        let key = String(trimmed[..<colon])
        guard !key.isEmpty, !key.contains(" ") else { return nil }
        var rest = String(trimmed[trimmed.index(after: colon)...])
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        if let comment = rest.range(of: " #") {
            rest = String(rest[..<comment.lowerBound])
        }
        return (key, !rest.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private static func join(_ lines: [String], endsWithNewline: Bool) -> String {
        lines.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
    }
}
