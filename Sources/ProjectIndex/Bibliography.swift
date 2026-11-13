import Foundation

/// An entry of a BibTeX file, enough for completion and to check citation keys.
public struct BibEntry: Equatable, Sendable {
    public var key: String
    public var type: String
    public var title: String?
    public var authors: String?
    public var year: String?
    public var file: String

    /// "Nocedal 2006: Numerical Optimization".
    public var summary: String {
        let firstAuthor = authors?.components(separatedBy: " and ").first?
            .components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces)
        let who = [firstAuthor, year].compactMap { $0 }.joined(separator: " ")
        return [who.isEmpty ? nil : who, title].compactMap { $0 }.joined(separator: ": ")
    }
}

public enum BibTeX {
    /// Reads `@type{key, field = {value}, …}` entries. Braces, quotes and nesting in values are
    /// handled; `@comment`, `@string` and `@preamble` are skipped.
    public static func entries(in text: String, file: String) -> [BibEntry] {
        let chars = Array(text)
        var entries: [BibEntry] = []
        var i = 0
        while i < chars.count {
            guard chars[i] == "@" else { i += 1; continue }
            var j = i + 1
            while j < chars.count, chars[j].isLetter { j += 1 }
            let type = String(chars[(i + 1)..<j]).lowercased()
            while j < chars.count, chars[j].isWhitespace { j += 1 }
            guard j < chars.count, chars[j] == "{" || chars[j] == "(" else { i = j; continue }
            let close: Character = chars[j] == "{" ? "}" : ")"
            // The body runs to the matching close, counting nested braces.
            var depth = 0
            var k = j
            while k < chars.count {
                if chars[k] == "{" || chars[k] == "(" && close == ")" { depth += 1 }
                if chars[k] == "}" || chars[k] == ")" && close == ")" { depth -= 1; if depth == 0 { break } }
                k += 1
            }
            let body = String(chars[(j + 1)..<min(k, chars.count)])
            i = k + 1
            guard !["comment", "string", "preamble"].contains(type), let comma = body.firstIndex(of: ",") else { continue }
            let key = body[..<comma].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            let fields = parseFields(String(body[body.index(after: comma)...]))
            entries.append(BibEntry(key: key, type: type, title: fields["title"], authors: fields["author"], year: fields["year"], file: file))
        }
        return entries
    }

    private static func parseFields(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            while i < chars.count, chars[i].isWhitespace || chars[i] == "," { i += 1 }
            var j = i
            while j < chars.count, chars[j] != "=" , chars[j] != "," { j += 1 }
            guard j < chars.count, chars[j] == "=" else { break }
            let name = String(chars[i..<j]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            j += 1
            while j < chars.count, chars[j].isWhitespace { j += 1 }
            var value = ""
            if j < chars.count, chars[j] == "{" || chars[j] == "\"" {
                let open = chars[j]
                var depth = 0
                var k = j
                repeat {
                    if chars[k] == "{" { depth += 1 } else if chars[k] == "}" { depth -= 1 }
                    k += 1
                } while k < chars.count && (open == "{" ? depth > 0 : (chars[k] != "\"" || depth > 0))
                value = String(chars[(j + 1)..<min(open == "{" ? k - 1 : k, chars.count)])
                i = open == "{" ? k : k + 1
            } else {
                var k = j
                while k < chars.count, chars[k] != "," { k += 1 }
                value = String(chars[j..<k])
                i = k
            }
            let cleaned = value.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
                .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            fields[name] = cleaned
        }
        return fields
    }
}

/// A BibTeX entry with all its fields, in order, and where it is in its file — for editing.
public struct BibRecord: Equatable, Identifiable, Sendable {
    public struct Field: Equatable, Identifiable, Sendable {
        public var id = UUID()
        public var name: String
        /// The value as written between the outer braces or quotes (inner braces kept).
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }

        public static func == (a: Field, b: Field) -> Bool { a.name == b.name && a.value == b.value }
    }

    public var type: String
    public var key: String
    public var fields: [Field]
    public var file: String
    /// The entry's text in its file, from `@` to the closing brace.
    public var range: Range<String.Index>?

    public var id: String { file + "#" + key }

    public init(type: String, key: String, fields: [Field], file: String, range: Range<String.Index>? = nil) {
        self.type = type
        self.key = key
        self.fields = fields
        self.file = file
        self.range = range
    }

    public static func == (a: BibRecord, b: BibRecord) -> Bool {
        a.type == b.type && a.key == b.key && a.fields == b.fields && a.file == b.file
    }

    public subscript(field: String) -> String? {
        fields.first { $0.name.lowercased() == field }.map { BibTeX.plain($0.value) }
    }

    /// "Nocedal, Wright" from "Nocedal, Jorge and Wright, Stephen J." (last names).
    public var authorNames: String {
        guard let authors = self["author"] ?? self["editor"] else { return "" }
        let names = authors.components(separatedBy: " and ").map { name -> String in
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if let comma = trimmed.firstIndex(of: ",") { return String(trimmed[..<comma]) }
            return trimmed.components(separatedBy: " ").last ?? trimmed
        }
        return names.count > 3 ? names.prefix(3).joined(separator: ", ") + " et al." : names.joined(separator: ", ")
    }

    /// The entry as BibTeX text, one field per line.
    public var text: String {
        var lines = ["@\(type){\(key),"]
        for field in fields where !field.name.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append("  \(field.name.trimmingCharacters(in: .whitespaces).lowercased()) = {\(field.value)},")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    /// Fields usually given for each entry type, in a sensible order.
    public static func suggestedFields(for type: String) -> [String] {
        switch type {
        case "article": return ["author", "title", "journal", "year", "volume", "number", "pages", "doi"]
        case "book": return ["author", "title", "publisher", "year", "address", "edition", "isbn"]
        case "inproceedings", "conference": return ["author", "title", "booktitle", "year", "pages", "publisher", "doi"]
        case "incollection": return ["author", "title", "booktitle", "editor", "publisher", "year", "pages"]
        case "phdthesis", "mastersthesis": return ["author", "title", "school", "year"]
        case "techreport": return ["author", "title", "institution", "year", "number"]
        case "online": return ["author", "title", "url", "year", "urldate"]
        default: return ["author", "title", "year", "howpublished", "note"]
        }
    }

    public static let types = ["article", "book", "inproceedings", "incollection", "phdthesis", "mastersthesis", "techreport", "online", "misc", "unpublished"]
}

extension BibTeX {
    /// All entries of a file with their fields and positions.
    public static func records(in text: String, file: String) -> [BibRecord] {
        var indices = Array(text.indices)
        indices.append(text.endIndex)
        let chars = Array(text)
        var records: [BibRecord] = []
        var i = 0
        while i < chars.count {
            guard chars[i] == "@" else { i += 1; continue }
            var j = i + 1
            while j < chars.count, chars[j].isLetter { j += 1 }
            let type = String(chars[(i + 1)..<j]).lowercased()
            while j < chars.count, chars[j].isWhitespace { j += 1 }
            guard j < chars.count, chars[j] == "{" || chars[j] == "(" else { i = j; continue }
            var depth = 0
            var k = j
            while k < chars.count {
                if chars[k] == "{" || chars[k] == "(" { depth += 1 }
                if chars[k] == "}" || chars[k] == ")" { depth -= 1; if depth == 0 { break } }
                k += 1
            }
            let body = String(chars[(j + 1)..<min(k, chars.count)])
            let end = min(k + 1, chars.count)
            defer { i = end }
            guard !["comment", "string", "preamble"].contains(type), let comma = body.firstIndex(of: ",") else { continue }
            let key = body[..<comma].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            let fields = rawFields(String(body[body.index(after: comma)...])).map { BibRecord.Field(name: $0.0, value: $0.1) }
            records.append(BibRecord(type: type, key: key, fields: fields, file: file, range: indices[i]..<indices[end]))
        }
        return records
    }

    /// `text` with `record` (found by its key) replaced by `replacement`, removed when nil, or
    /// `replacement` appended when there is no such entry.
    public static func replacing(key: String, with replacement: BibRecord?, in text: String, file: String) -> String {
        if let old = records(in: text, file: file).first(where: { $0.key == key }), let range = old.range {
            var result = text
            if let replacement {
                result.replaceSubrange(range, with: replacement.text)
            } else {
                // Also drop the blank line that separated the entry from the next.
                var upper = range.upperBound
                while upper < result.endIndex, result[upper] == "\n" { upper = result.index(after: upper) }
                result.removeSubrange(range.lowerBound..<upper)
            }
            return result
        }
        guard let replacement else { return text }
        let separator = text.isEmpty || text.hasSuffix("\n\n") ? "" : (text.hasSuffix("\n") ? "\n" : "\n\n")
        return text + separator + replacement.text + "\n"
    }

    /// A field value for display: braces removed, whitespace collapsed.
    public static func plain(_ value: String) -> String {
        value.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Fields in order, values as written inside their outer braces or quotes.
    static func rawFields(_ text: String) -> [(String, String)] {
        var fields: [(String, String)] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            while i < chars.count, chars[i].isWhitespace || chars[i] == "," { i += 1 }
            var j = i
            while j < chars.count, chars[j] != "=", chars[j] != "," { j += 1 }
            guard j < chars.count, chars[j] == "=" else { break }
            let name = String(chars[i..<j]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            j += 1
            while j < chars.count, chars[j].isWhitespace { j += 1 }
            var value = ""
            if j < chars.count, chars[j] == "{" {
                var depth = 0
                var k = j
                repeat {
                    if chars[k] == "{" { depth += 1 } else if chars[k] == "}" { depth -= 1 }
                    k += 1
                } while k < chars.count && depth > 0
                value = String(chars[(j + 1)..<max(j + 1, k - 1)])
                i = k
            } else if j < chars.count, chars[j] == "\"" {
                var k = j + 1
                var depth = 0
                while k < chars.count, chars[k] != "\"" || depth > 0 {
                    if chars[k] == "{" { depth += 1 } else if chars[k] == "}" { depth -= 1 }
                    k += 1
                }
                value = String(chars[(j + 1)..<min(k, chars.count)])
                i = k + 1
            } else {
                var k = j
                while k < chars.count, chars[k] != "," { k += 1 }
                value = String(chars[j..<k]).trimmingCharacters(in: .whitespacesAndNewlines)
                i = k
            }
            fields.append((name, value))
        }
        return fields
    }
}
