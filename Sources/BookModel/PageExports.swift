import Foundation

/// The YAML front matter of a Markdown page (between `---` lines at the top).
public enum FrontMatter {
    /// The front matter's YAML (without the `---` lines) and the rest of the page.
    /// `yaml` is nil when the page has no front matter.
    public static func split(_ text: String) -> (yaml: String?, body: String) {
        guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else { return (nil, text) }
        let lines = text.components(separatedBy: "\n")
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return (nil, text)
        }
        let yaml = lines[1..<end].joined(separator: "\n")
        let body = lines[(end + 1)...].joined(separator: "\n")
        return (yaml.isEmpty ? "" : yaml + "\n", body)
    }

    /// `text` with `path` in its front matter set to `value` (removed when nil). Front matter is
    /// added when needed and removed when it becomes empty; the rest of the page is unchanged.
    public static func setting(_ path: [String], to value: YAMLValue?, in text: String) throws -> String {
        let (yaml, body) = split(text)
        let updated = try YAMLEditor.setting(path, to: value, in: yaml ?? "")
        if updated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Drop an empty block, and the blank line written after it.
            return yaml == nil ? text : (body.hasPrefix("\n") ? String(body.dropFirst()) : body)
        }
        let separator = yaml == nil ? "\n" : ""
        return "---\n" + updated + (updated.hasSuffix("\n") ? "" : "\n") + "---\n" + separator + body
    }

    public static func value(at path: [String], in text: String) -> YAMLValue? {
        guard let yaml = split(text).yaml else { return nil }
        return YAMLEditor.value(at: path, in: yaml)
    }
}

/// The exports and downloads of one page, from its front matter.
///
/// `exports` lists documents MyST builds from the page (`myst build --pdf` builds every page that
/// lists a pdf export). `downloads` lists files offered on the page, such as a PDF made elsewhere.
/// When a page has downloads, MyST shows only those, so the page's own exports are listed there too
/// (by id) to keep them downloadable.
public struct PageExports: Equatable {
    /// A file of the book offered on the page. MyST reads `file:` and `url:` (a path relative to the
    /// page); the key it was written with and keys the app does not edit (`filename`, `static`) are kept.
    public struct Download: Equatable, Identifiable {
        public var id = UUID()
        public var file: String
        public var title: String
        /// "file" or "url".
        public var key: String
        public var otherKeys: [YAMLPair]

        public init(file: String, title: String = "", key: String = "file", otherKeys: [YAMLPair] = []) {
            self.file = file
            self.title = title
            self.key = key
            self.otherKeys = otherKeys
        }

        public static func == (a: Download, b: Download) -> Bool {
            a.file == b.file && a.title == b.title && a.key == b.key && a.otherKeys == b.otherKeys
        }
    }

    /// Formats exported with MyST's defaults, in the order of `ProjectSettings.exportFormats`.
    public var formats: [String] = []
    /// Downloads of files that already exist (made by hand or elsewhere).
    public var downloads: [Download] = []
    /// Export entries with settings the app does not edit (a template, an output path, …); kept.
    public var otherExports: [YAMLValue] = []
    /// Download entries other than files and the page's own export ids (e.g. URLs); kept.
    public var otherDownloads: [YAMLValue] = []

    public init() {}

    public init(page text: String) {
        if case .list(let items) = FrontMatter.value(at: ["exports"], in: text) {
            for item in items {
                // A plain `- format: pdf` (maybe with the id the app writes) is a simple format toggle.
                let keys = Set(item.pairs?.map(\.key) ?? [])
                if let format = item["format"]?.string, keys.isSubset(of: ["format", "id"]), !formats.contains(format) {
                    formats.append(format)
                } else {
                    otherExports.append(item)
                }
            }
        }
        if case .list(let items) = FrontMatter.value(at: ["downloads"], in: text) {
            for item in items {
                let keys = item.pairs?.map(\.key) ?? []
                let key = keys.contains("file") ? "file" : "url"
                if let file = item[key]?.string, !file.contains("://"), !(keys.contains("file") && keys.contains("url")) {
                    let others = (item.pairs ?? []).filter { $0.key != key && $0.key != "title" }
                    downloads.append(Download(file: file, title: item["title"]?.string ?? "", key: key, otherKeys: others))
                } else if item["id"] != nil, Set(item.pairs?.map(\.key) ?? []).isSubset(of: ["id", "title"]) {
                    continue // the page's own exports, written again from `formats`
                } else {
                    otherDownloads.append(item)
                }
            }
        }
    }

    public var isEmpty: Bool { formats.isEmpty && downloads.isEmpty && otherExports.isEmpty && otherDownloads.isEmpty }

    /// An export id unique in the book: the page path and the format.
    public static func exportID(page: String, format: String) -> String {
        BookProject.slug(for: (page as NSString).deletingPathExtension) + "-" + format.replacingOccurrences(of: "+", with: "-")
    }

    /// `text` (a page) with these exports and downloads written into its front matter.
    public func applying(to text: String, page: String) throws -> String {
        let order = ProjectSettings.exportFormats
        let sorted = formats.sorted { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }
        let exportItems: [YAMLValue] = sorted.map {
            .map([YAMLPair("format", .string($0)), YAMLPair("id", .string(Self.exportID(page: page, format: $0)))])
        } + otherExports
        var downloadItems: [YAMLValue] = downloads.filter { !$0.file.trimmingCharacters(in: .whitespaces).isEmpty }.map { download in
            var pairs = [YAMLPair(download.key, .string(download.file))]
            if !download.title.isEmpty { pairs.append(YAMLPair("title", .string(download.title))) }
            return .map(pairs + download.otherKeys)
        } + otherDownloads
        if !downloadItems.isEmpty {
            downloadItems += sorted.map {
                .map([YAMLPair("id", .string(Self.exportID(page: page, format: $0))), YAMLPair("title", .string(Self.title(of: $0)))])
            }
        }
        var result = try FrontMatter.setting(["exports"], to: exportItems.isEmpty ? nil : .list(exportItems), in: text)
        result = try FrontMatter.setting(["downloads"], to: downloadItems.isEmpty ? nil : .list(downloadItems), in: result)
        return result
    }

    /// How a format is named on the page's download button.
    public static func title(of format: String) -> String {
        switch format {
        case "pdf", "pdf+tex": return "PDF"
        case "typst": return "PDF (Typst)"
        case "docx": return "Word"
        case "tex": return "LaTeX"
        case "md": return "Markdown"
        default: return format
        }
    }

    /// The `myst build` flags for these formats.
    public var buildFlags: [String] {
        (formats + otherExports.compactMap { $0["format"]?.string }).map { ProjectSettings.Export(format: $0).buildFlag }
    }
}
