import BookModel
import Foundation
import MystSyntax
import ProjectIndex

/// How the book view shows references: the target's title, a citation as "Author, Year".
extension BookStore {
    /// The text for `{role}`target`` in `page`, or nil when the target is unknown (the book view then
    /// shows the target as written).
    func referenceText(role: String, target: String, page: String) -> String? {
        if MystCatalog.citationRoles.contains(role) {
            let keys = target.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let entries = keys.compactMap { index.citations[$0] }
            guard entries.count == keys.count, !entries.isEmpty else { return nil }
            let textual = role.hasPrefix("cite:t")
            let all = role.hasSuffix("s")
            let parts = entries.map { entry -> String in
                let who = Self.citationAuthors(entry.authors, all: all)
                let year = entry.year ?? "n.d."
                return textual ? "\(who) (\(year))" : "\(who), \(year)"
            }
            return textual ? parts.joined(separator: "; ") : "(" + parts.joined(separator: "; ") + ")"
        }
        switch role {
        case "ref", "numref":
            guard let definition = index.definitions(of: target).first else { return nil }
            // A figure's or table's label title is its file or empty; its caption says what it shows.
            let captioned: Set<LabelKind> = [.figure, .table, .code]
            let named = captioned.contains(definition.label.kind) ? definition.label.snippet : definition.label.title
            let title = (named ?? definition.label.title)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let title, !title.isEmpty else { return nil }
            if role == "numref" {
                let kind: String
                switch definition.label.kind {
                case .figure: kind = "Figure"
                case .table: kind = "Table"
                case .equation: kind = "Equation"
                case .code: kind = "Program"
                case .heading, .page: kind = "Section"
                default: kind = ""
                }
                return kind.isEmpty ? title : "\(kind) “\(title)”"
            }
            return title
        case "eq":
            return index.definitions(of: target).isEmpty ? nil : "(\(target))"
        case "doc":
            guard let project else { return nil }
            let folder = (page as NSString).deletingLastPathComponent
            var path = target.hasPrefix("/") ? String(target.dropFirst()) : (folder.isEmpty ? target : folder + "/" + target)
            path = (path as NSString).standardizingPath
            if (path as NSString).pathExtension.isEmpty { path += ".md" }
            guard project.fileExists(path) else { return nil }
            if let entry = project.entries(forFile: path).first { return project.displayTitle(for: entry) }
            return index.pages[path]?.labels.first { $0.kind == .page }?.title ?? (path as NSString).deletingPathExtension
        default:
            return nil
        }
    }

    /// "Smith", "Smith & Jones", "Smith et al." (or every name with `all`).
    static func citationAuthors(_ authors: String?, all: Bool) -> String {
        let names = (authors ?? "").components(separatedBy: " and ").map { name -> String in
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            // "Last, First" or "First Last".
            if let comma = trimmed.firstIndex(of: ",") { return String(trimmed[..<comma]) }
            return trimmed.split(separator: " ").last.map(String.init) ?? trimmed
        }.filter { !$0.isEmpty }
        guard let first = names.first else { return "Anonymous" }
        if names.count == 1 { return first }
        if all || names.count == 2 { return names.dropLast().joined(separator: ", ") + " & " + names.last! }
        return first + " et al."
    }
}
