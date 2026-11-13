import Foundation
import MystSyntax

/// A problem found in a page while editing, without running MyST.
public struct Diagnostic: Equatable, Sendable, Identifiable {
    public enum Severity: String, Sendable { case warning, error }

    public var severity: Severity
    public var message: String
    public var range: NSRange
    public var line: Int
    public var id: String { "\(line):\(range.location):\(message)" }
}

extension ProjectIndex {
    /// Problems in `page`: unknown labels and citation keys, unknown directives and roles,
    /// missing files, and labels defined more than once in the book.
    public func diagnostics(for page: String) -> [Diagnostic] {
        guard let symbols = pages[page] else { return [] }
        var result: [Diagnostic] = []
        let allLabels = Set(labels.map(\.label.name))

        for reference in symbols.references {
            switch reference.kind {
            case .role(let role):
                guard !reference.target.contains(":") else { continue } // xref:… and project-prefixed labels
                if !allLabels.contains(reference.target) {
                    result.append(Diagnostic(severity: .warning, message: "Unknown label “\(reference.target)” in {\(role)}",
                                             range: reference.range, line: reference.line))
                }
            case .link:
                if !allLabels.contains(reference.target) && !symbols.headingAnchors.contains(reference.target) {
                    result.append(Diagnostic(severity: .warning, message: "No label or heading “#\(reference.target)” on this page or in the book",
                                             range: reference.range, line: reference.line))
                }
            case .citation:
                if hasBibliography && citations[reference.target] == nil {
                    result.append(Diagnostic(severity: .warning, message: "Unknown citation key “\(reference.target)”",
                                             range: reference.range, line: reference.line))
                }
            }
        }

        if !hasUnreadPlugins {
            for usage in symbols.directives where directive(usage.name) == nil {
                result.append(Diagnostic(severity: .warning, message: "Unknown directive {\(usage.name)}", range: usage.range, line: usage.line))
            }
            for usage in symbols.roles where role(usage.name) == nil {
                result.append(Diagnostic(severity: .warning, message: "Unknown role {\(usage.name)}", range: usage.range, line: usage.line))
            }
        }

        for file in symbols.files {
            guard let resolved = PagePath.resolve(file.path, from: page) else { continue }
            let exists: Bool
            if resolved.hasSuffix(".*") {
                // `name.*` lets MyST pick the best of several formats (e.g. name.svg and name.pdf).
                let stem = String(resolved.dropLast(2))
                exists = files.contains { ($0 as NSString).deletingPathExtension == stem }
            } else {
                switch file.via {
            case "doc":
                exists = files.contains(resolved + ".md") || files.contains(resolved) || files.contains(resolved + ".ipynb")
            case "link":
                // A link to a page may leave out ".md"; links to other files must exist as written.
                exists = files.contains(resolved) || files.contains(resolved + ".md") || files.contains(where: { $0.hasPrefix(resolved + "/") })
                default:
                    exists = files.contains(resolved)
                }
            }
            if !exists {
                result.append(Diagnostic(severity: .error, message: "File not found: \(file.path)", range: file.range, line: file.line))
            }
        }

        for target in symbols.braceTargets {
            result.append(Diagnostic(severity: .warning,
                                     message: "Labels are written in round brackets: (\(target.name))= — with braces MyST does not read it as a label",
                                     range: target.range, line: target.line))
        }

        for label in symbols.labels {
            let others = definitions(of: label.name).filter { !($0.page == page && $0.label.range == label.range) }
            if let other = others.first {
                result.append(Diagnostic(severity: .warning,
                                         message: "Label “\(label.name)” is also defined in \(other.page == page ? "this page" : other.page), line \(other.label.line)",
                                         range: label.range, line: label.line))
            }
        }
        return result.sorted { ($0.line, $0.range.location) < ($1.line, $1.range.location) }
    }
}
