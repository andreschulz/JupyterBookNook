import Foundation

/// One entry of `project.plugins` in `myst.yml`: a JavaScript file in the book, a URL, or an
/// executable (`{type: executable, path: …}`). The value is kept as written, so entries the app
/// does not understand are written back unchanged.
public struct PluginEntry: Equatable, Sendable, Identifiable {
    public var value: YAMLValue

    public init(_ value: YAMLValue) {
        self.value = value
    }

    /// A JavaScript plugin from a path in the book or a URL.
    public static func javascript(_ source: String) -> PluginEntry {
        PluginEntry(.string(source))
    }

    /// The path or URL.
    public var source: String {
        value.string ?? value["path"]?.string ?? value["url"]?.string ?? ""
    }

    public var isExecutable: Bool { value["type"]?.string == "executable" }
    public var isURL: Bool { source.hasPrefix("https://") || source.hasPrefix("http://") }
    public var id: String { source }

    /// The file name without its extension: "unsplash" for `plugins/unsplash.mjs`.
    public var fileName: String {
        let last = isURL ? (URL(string: source)?.lastPathComponent ?? source) : (source as NSString).lastPathComponent
        let stem = (last as NSString).deletingPathExtension
        return stem.isEmpty ? source : stem
    }

    /// The entry as one line of YAML, for keeping it while it is disabled.
    public var yaml: String {
        YAMLEditor.render("plugin", value, indent: "").joined(separator: "\n")
    }

    public init?(yaml: String) {
        guard let value = YAMLEditor.value(at: ["plugin"], in: yaml) else { return nil }
        self.init(value)
    }
}

extension BookProject {
    /// The plugins `myst.yml` lists, in order.
    public var plugins: [PluginEntry] {
        guard case .list(let items)? = YAMLEditor.value(at: ["project", "plugins"], in: configText) else { return [] }
        return items.map(PluginEntry.init)
    }

    /// Writes `entries` as `project.plugins` (removing the key when empty), plus `operations`.
    @discardableResult
    public mutating func setPlugins(_ entries: [PluginEntry], operations: [FileOperation] = [], summary: String) throws -> StructuralChange? {
        guard entries != plugins || !operations.isEmpty else { return nil }
        return try commit(toc: nil, operations: operations, summary: summary + " — myst.yml updated") { text in
            try YAMLEditor.setting(["project", "plugins"], to: entries.isEmpty ? nil : .list(entries.map(\.value)), in: text)
        }
    }

    /// Copies a plugin file from outside the book into the plugins folder and adds it.
    public mutating func addPluginFile(copying url: URL) throws -> (path: String, change: StructuralChange?) {
        let path = uniquePath(folder: folders.plugins, name: url.lastPathComponent)
        let data = try Data(contentsOf: url)
        let change = try setPlugins(plugins + [.javascript(path)], operations: [.createdData(self.url(for: path), data)],
                                    summary: "Added the plugin \(path)")
        return (path, change)
    }

    /// Creates `<plugins folder>/<name>.mjs` from the starter plugin and adds it.
    public mutating func addNewPlugin(named name: String) throws -> (path: String, change: StructuralChange?) {
        let slug = Self.pluginSlug(name)
        let path = uniquePath(folder: folders.plugins, name: slug + ".mjs")
        let source = Self.starterPlugin(title: name, directive: slug)
        let change = try setPlugins(plugins + [.javascript(path)], operations: [.created(self.url(for: path), contents: source)],
                                    summary: "Created the plugin \(path)")
        return (path, change)
    }

    /// "My Boxes" → "my-boxes": a name usable for a file and a directive.
    static func pluginSlug(_ name: String) -> String {
        let words = name.lowercased().split { !$0.isLetter && !$0.isNumber }
        let slug = words.joined(separator: "-")
        return slug.isEmpty ? "my-plugin" : slug
    }

    /// A small, working plugin with one directive and one role, to start from.
    static func starterPlugin(title: String, directive name: String) -> String {
        let escapedTitle = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        return """
        // A MyST plugin, listed under project.plugins in myst.yml. It runs during every build.
        // Guide: https://mystmd.org/guide/plugins — the tree it returns is MyST's AST (https://mystmd.org/spec).

        /** The {\(name)} directive: a box with a title and the content written inside it. */
        const \(Self.identifier(name))Directive = {
          name: '\(name)',
          doc: 'A box with a title.',
          arg: { type: String, doc: 'The title of the box' },
          options: {
            class: { type: String, doc: 'CSS classes for the box' },
          },
          body: { type: 'myst', doc: 'The content of the box' },
          run(data) {
            return [
              {
                type: 'admonition',
                kind: 'note',
                class: data.options?.class,
                children: [
                  { type: 'admonitionTitle', children: [{ type: 'text', value: data.arg ?? '\(escapedTitle)' }] },
                  ...(data.body ?? []),
                ],
              },
            ];
          },
        };

        /** The {\(name)} role: its text in bold. */
        const \(Self.identifier(name))Role = {
          name: '\(name)',
          doc: 'Text in bold.',
          body: { type: String, doc: 'The text' },
          run(data) {
            return [{ type: 'strong', children: [{ type: 'text', value: data.body }] }];
          },
        };

        const plugin = {
          name: '\(escapedTitle)',
          directives: [\(Self.identifier(name))Directive],
          roles: [\(Self.identifier(name))Role],
        };

        export default plugin;

        """
    }

    /// "my-boxes" → "myBoxes".
    static func identifier(_ slug: String) -> String {
        let parts = slug.split(separator: "-").map(String.init)
        guard let first = parts.first else { return "plugin" }
        let joined = first + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        return joined.first?.isNumber == true ? "plugin" + joined : joined
    }
}
