import Foundation

/// The URL path of each page in a MyST site.
public enum MystSlugs {
    /// MyST's own mapping from page file to URL, read from the site content that
    /// `myst start` and `myst build` write to `_build/site/content`. Keys are project-relative paths.
    public static func fromSite(projectRoot: URL) -> [String: String] {
        let folder = projectRoot.appendingPathComponent("_build/site/content", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [:] }
        var slugs: [String: String] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let location = object["location"] as? String, let slug = object["slug"] as? String else { continue }
            slugs[location.hasPrefix("/") ? String(location.dropFirst()) : location] = slug
        }
        return slugs
    }

    /// The same mapping computed from the table of contents, for when MyST has not written the
    /// site yet: the first page is "index"; others use the file name, lowercased, with leading
    /// numbers removed and other characters replaced by "-"; repeats get "-1", "-2", ….
    public static func computed(pages: [String]) -> [String: String] {
        var slugs: [String: String] = [:]
        var used = Set<String>()
        for (index, page) in pages.enumerated() where slugs[page] == nil {
            var slug = index == 0 ? "index" : slugify((page as NSString).lastPathComponent)
            if used.contains(slug) {
                var n = 1
                while used.contains("\(slug)-\(n)") { n += 1 }
                slug = "\(slug)-\(n)"
            }
            used.insert(slug)
            slugs[page] = slug
        }
        return slugs
    }

    /// The URL path for a slug: the index page is the site root.
    public static func path(for slug: String) -> String {
        slug == "index" ? "/" : "/" + slug
    }

    static func slugify(_ fileName: String) -> String {
        var stem = fileName
        for ext in [".md", ".ipynb", ".myst"] where stem.lowercased().hasSuffix(ext) {
            stem.removeLast(ext.count)
        }
        if let numbers = stem.range(of: #"^\d+[-_.\s]*"#, options: .regularExpression), numbers.upperBound < stem.endIndex {
            stem.removeSubrange(numbers)
        }
        var slug = ""
        for scalar in stem.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                slug.unicodeScalars.append(scalar)
            } else if !slug.isEmpty && !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "page" : slug
    }
}
