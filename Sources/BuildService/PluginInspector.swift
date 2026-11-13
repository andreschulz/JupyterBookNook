import Foundation

/// What a MyST plugin adds: its directives, roles and transforms.
public struct PluginSpec: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var name: String
        public var aliases: [String]
        public var doc: String?
        public var options: [String]

        public init(name: String, aliases: [String] = [], doc: String? = nil, options: [String] = []) {
            self.name = name
            self.aliases = aliases
            self.doc = doc
            self.options = options
        }
    }

    public var name: String?
    public var directives: [Item]
    public var roles: [Item]
    public var transforms: [String]

    public init(name: String? = nil, directives: [Item] = [], roles: [Item] = [], transforms: [String] = []) {
        self.name = name
        self.directives = directives
        self.roles = roles
        self.transforms = transforms
    }

    public var isEmpty: Bool { directives.isEmpty && roles.isEmpty && transforms.isEmpty }
}

public enum PluginInspectorError: LocalizedError, Equatable {
    case noNode
    case failed(String)
    case notAPlugin

    public var errorDescription: String? {
        switch self {
        case .noNode: return "Node.js was not found, and the file could not be read without it."
        case .failed(let message): return message
        case .notAPlugin: return "The file does not export a MyST plugin (an object with directives, roles or transforms)."
        }
    }
}

/// Finds out what a JavaScript plugin adds. With Node.js the plugin is imported and its exports
/// are read, which is exact; without it the source is scanned for the usual way of writing a
/// plugin (`directives: [ … ]` with `name: '…'`), which may miss names in bundled code.
public enum PluginInspector {
    /// Imports the plugin in `node` and prints what it exports. The plugin's own top-level code
    /// runs, as it does in every build.
    static let script = #"""
    import { pathToFileURL } from 'node:url';
    const file = process.argv[1];
    const list = (value) => Array.isArray(value) ? value : [];
    const item = (d) => ({
      name: String(d?.name ?? ''),
      aliases: Array.isArray(d?.alias) ? d.alias.map(String) : (d?.alias ? [String(d.alias)] : []),
      doc: typeof d?.doc === 'string' ? d.doc : null,
      options: Object.keys(d?.options ?? {}),
    });
    try {
      const m = await import(pathToFileURL(file).href);
      const p = m.default ?? m.plugin ?? m;
      const out = {
        name: typeof p?.name === 'string' ? p.name : null,
        directives: list(p?.directives).map(item),
        roles: list(p?.roles).map(item),
        transforms: list(p?.transforms).map((t) => String(t?.name ?? 'transform')),
      };
      process.stdout.write('NOOK_PLUGIN ' + JSON.stringify(out) + '\n');
      process.exit(0);
    } catch (e) {
      process.stdout.write('NOOK_ERROR ' + String(e?.message ?? e).split('\n')[0] + '\n');
      process.exit(1);
    }
    """#

    /// The plugin in `file`: imported with `node` when given, else scanned.
    public static func inspect(file: URL, node: String?, searchPath: [String]) async -> Result<PluginSpec, PluginInspectorError> {
        if let node {
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = searchPath.joined(separator: ":")
            do {
                let output = try await ProcessRunner.run(node, ["--input-type=module", "-e", script, file.path], environment: environment,
                                                         in: file.deletingLastPathComponent(), timeout: 20)
                if let line = output.lines.last(where: { $0.hasPrefix("NOOK_PLUGIN ") }),
                   let spec = try? JSONDecoder().decode(PluginSpec.self, from: Data(line.dropFirst(12).utf8)) {
                    return spec.isEmpty ? .failure(.notAPlugin) : .success(spec)
                }
                if let line = output.lines.last(where: { $0.hasPrefix("NOOK_ERROR ") }) {
                    return .failure(.failed(String(line.dropFirst(11))))
                }
                return .failure(.failed(output.lines.last { !$0.isEmpty } ?? "Node.js stopped (exit code \(output.exitCode))."))
            } catch {
                return .failure(.failed(error.localizedDescription))
            }
        }
        guard let source = try? String(contentsOf: file, encoding: .utf8) else { return .failure(.failed("The file could not be read.")) }
        if let spec = scan(source) { return .success(spec) }
        return .failure(.noNode)
    }

    /// `node` in the toolchain's folders or on the search path.
    public static func findNode(in directories: [String]) -> String? {
        directories.map { ($0 as NSString).appendingPathComponent("node") }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Downloads a plugin given as a URL into `folder`, named after a hash of the URL, so it can be
    /// inspected. MyST downloads it again itself when building.
    public static func download(_ url: URL, into folder: URL) async throws -> URL {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PluginInspectorError.failed("The server answered \(http.statusCode).")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = cacheFile(for: url, in: folder)
        try data.write(to: file, options: .atomic)
        return file
    }

    /// Where `download` puts the plugin at `url`.
    public static func cacheFile(for url: URL, in folder: URL) -> URL {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in url.absoluteString.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        let ext = url.pathExtension.isEmpty ? "mjs" : url.pathExtension
        return folder.appendingPathComponent(String(hash, radix: 16) + "." + ext)
    }

    // MARK: Scanning without Node

    /// Reads `directives: [ … ]`, `roles: [ … ]` and `transforms: [ … ]` from plugin source, with
    /// items written inline or as constants defined in the same file. Nil when none are found.
    public static func scan(_ source: String) -> PluginSpec? {
        let scanner = SourceScanner(source)
        var spec = PluginSpec()
        var found = false
        for key in ["directives", "roles", "transforms"] {
            for (keyStart, body) in scanner.arrays(named: key) {
                found = true
                let items = scanner.split(body).compactMap { scanner.object(forItem: $0) }.map { scanner.item(from: $0) }
                switch key {
                case "directives": spec.directives += items
                case "roles": spec.roles += items
                default: spec.transforms += items.map { $0.name.isEmpty ? "transform" : $0.name }
                }
                if spec.name == nil, let owner = scanner.enclosingObject(of: keyStart) {
                    spec.name = scanner.entries(of: owner).first { $0.key == "name" }.flatMap { scanner.stringValue($0.value) }
                }
            }
        }
        spec.directives.removeAll { $0.name.isEmpty }
        spec.roles.removeAll { $0.name.isEmpty }
        return found && !spec.isEmpty ? spec : nil
    }
}

/// A rough JavaScript reader: matches brackets while skipping strings and comments.
struct SourceScanner {
    let chars: [Character]

    init(_ source: String) {
        chars = Array(source)
    }

    func text(_ range: Range<Int>) -> String { String(chars[range]) }

    /// Index after a string, comment or template starting at `i`, or nil when none starts there.
    private func skipLiteral(at i: Int) -> Int? {
        let c = chars[i]
        if c == "/", i + 1 < chars.count {
            if chars[i + 1] == "/" {
                var j = i + 2
                while j < chars.count, chars[j] != "\n" { j += 1 }
                return j
            }
            if chars[i + 1] == "*" {
                var j = i + 2
                while j + 1 < chars.count, !(chars[j] == "*" && chars[j + 1] == "/") { j += 1 }
                return min(chars.count, j + 2)
            }
        }
        if c == "'" || c == "\"" || c == "`" {
            var j = i + 1
            while j < chars.count, chars[j] != c {
                if chars[j] == "\\" { j += 1 }
                if c != "`", chars[j] == "\n" { break }
                j += 1
            }
            return min(chars.count, j + 1)
        }
        return nil
    }

    /// The index of the bracket closing the one at `open`.
    func closing(_ open: Int) -> Int? {
        var depth = 0
        var i = open
        while i < chars.count {
            if let next = skipLiteral(at: i) {
                i = next
                continue
            }
            switch chars[i] {
            case "{", "[", "(": depth += 1
            case "}", "]", ")":
                depth -= 1
                if depth == 0 { return i }
            default: break
            }
            i += 1
        }
        return nil
    }

    /// Positions of code (not strings or comments), for searching.
    private var codeIndices: [Int] {
        var result: [Int] = []
        var i = 0
        while i < chars.count {
            if let next = skipLiteral(at: i) {
                i = next
                continue
            }
            result.append(i)
            i += 1
        }
        return result
    }

    private func isIdentifier(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "$" }

    /// Every `key: [ … ]` (or `key = [ … ]`): where the key starts and the array's contents.
    func arrays(named key: String) -> [(Int, Range<Int>)] {
        let word = Array(key)
        var result: [(Int, Range<Int>)] = []
        for i in codeIndices where chars[i] == word[0] && i + word.count <= chars.count && Array(chars[i..<i + word.count]) == word {
            if i > 0, isIdentifier(chars[i - 1]) { continue }
            var j = i + word.count
            if j < chars.count, isIdentifier(chars[j]) { continue }
            while j < chars.count, chars[j].isWhitespace { j += 1 }
            guard j < chars.count, chars[j] == ":" || chars[j] == "=" else { continue }
            j += 1
            while j < chars.count, chars[j].isWhitespace { j += 1 }
            guard j < chars.count, chars[j] == "[", let end = closing(j) else { continue }
            result.append((i, j + 1..<end))
        }
        return result
    }

    /// `range` split at commas outside brackets, trimmed, empty parts dropped.
    func split(_ range: Range<Int>) -> [Range<Int>] {
        var parts: [Range<Int>] = []
        var start = range.lowerBound
        var i = range.lowerBound
        while i < range.upperBound {
            if let next = skipLiteral(at: i) {
                i = min(next, range.upperBound)
                continue
            }
            if "{[(".contains(chars[i]), let end = closing(i) {
                i = min(end + 1, range.upperBound)
                continue
            }
            if chars[i] == "," {
                parts.append(start..<i)
                start = i + 1
            }
            i += 1
        }
        parts.append(start..<range.upperBound)
        return parts.compactMap(trimmed).filter { !$0.isEmpty }
    }

    private func trimmed(_ range: Range<Int>) -> Range<Int>? {
        var lower = range.lowerBound, upper = range.upperBound
        while lower < upper, chars[lower].isWhitespace { lower += 1 }
        while upper > lower, chars[upper - 1].isWhitespace { upper -= 1 }
        // Comments around an item.
        while lower < upper, let next = skipLiteral(at: lower), chars[lower] == "/" {
            lower = next
            while lower < upper, chars[lower].isWhitespace { lower += 1 }
        }
        return lower..<upper
    }

    /// The object of an array item: written inline, or a constant `const name = { … }`.
    func object(forItem range: Range<Int>) -> Range<Int>? {
        if chars[range.lowerBound] == "{", let end = closing(range.lowerBound) { return range.lowerBound + 1..<end }
        let name = text(range)
        guard !name.isEmpty, name.allSatisfy(isIdentifier) else { return nil }
        let word = Array(name)
        for i in codeIndices where chars[i] == word[0] && i + word.count <= chars.count && Array(chars[i..<i + word.count]) == word {
            guard i > 0, !isIdentifier(chars[i - 1]) else { continue }
            let before = text(max(0, i - 8)..<i)
            guard before.hasSuffix("const ") || before.hasSuffix("let ") || before.hasSuffix("var ") else { continue }
            var j = i + word.count
            // A type annotation (TypeScript-like JSDoc builds) may come before `=`.
            while j < chars.count, chars[j] != "=", chars[j] != "\n", chars[j] != ";" { j += 1 }
            guard j < chars.count, chars[j] == "=" else { continue }
            j += 1
            while j < chars.count, chars[j].isWhitespace { j += 1 }
            if j < chars.count, chars[j] == "{", let end = closing(j) { return j + 1..<end }
        }
        return nil
    }

    /// The top-level `key: value` pairs of an object's contents. Methods (`run(data) { … }`)
    /// appear with their name as key.
    func entries(of range: Range<Int>) -> [(key: String, value: Range<Int>)] {
        split(range).compactMap { part in
            var i = part.lowerBound
            var key = ""
            if chars[i] == "'" || chars[i] == "\"" {
                guard let end = skipLiteral(at: i) else { return nil }
                key = text(i + 1..<end - 1)
                i = end
            } else {
                while i < part.upperBound, isIdentifier(chars[i]) || chars[i] == "-" { key.append(chars[i]); i += 1 }
            }
            while i < part.upperBound, chars[i].isWhitespace { i += 1 }
            guard !key.isEmpty, i < part.upperBound, chars[i] == ":" else { return (key, part.upperBound..<part.upperBound) }
            i += 1
            return (key, trimmed(i..<part.upperBound) ?? i..<part.upperBound)
        }
    }

    /// A string literal's text.
    func stringValue(_ range: Range<Int>) -> String? {
        guard range.count >= 2, let first = chars.indices.contains(range.lowerBound) ? chars[range.lowerBound] : nil,
              first == "'" || first == "\"" || first == "`", chars[range.upperBound - 1] == first else { return nil }
        let inner = text(range.lowerBound + 1..<range.upperBound - 1)
        return first == "`" && inner.contains("${") ? nil : inner
    }

    func item(from object: Range<Int>) -> PluginSpec.Item {
        let pairs = entries(of: object)
        func value(_ key: String) -> Range<Int>? { pairs.first { $0.key == key }?.value }
        var item = PluginSpec.Item(name: value("name").flatMap(stringValue) ?? "")
        item.doc = value("doc").flatMap(stringValue)
        if let alias = value("alias") {
            if chars[alias.lowerBound] == "[", let end = closing(alias.lowerBound) {
                item.aliases = split(alias.lowerBound + 1..<end).compactMap(stringValue)
            } else if let single = stringValue(alias) {
                item.aliases = [single]
            }
        }
        if let options = value("options"), chars[options.lowerBound] == "{", let end = closing(options.lowerBound) {
            item.options = entries(of: options.lowerBound + 1..<end).map(\.key)
        }
        return item
    }

    /// The contents of the object literal around `index`.
    func enclosingObject(of index: Int) -> Range<Int>? {
        var depth = 0
        var i = index - 1
        // Walking backwards cannot skip strings reliably; brackets inside strings are rare enough here.
        while i >= 0 {
            switch chars[i] {
            case "}", "]", ")": depth += 1
            case "[", "(": depth -= 1
            case "{":
                if depth == 0, let end = closing(i) { return i + 1..<end }
                depth -= 1
            default: break
            }
            i -= 1
        }
        return nil
    }
}
