import Foundation

/// A way to run MyST: the `myst` executable (mystmd, the engine of Jupyter Book 2), or
/// `jupyter-book`, which wraps it with the same commands, or a custom command such as `npx mystmd`.
public struct Toolchain: Hashable, Codable, Sendable {
    public enum Tool: String, Hashable, Codable, Sendable {
        case jupyterBook = "jupyter-book"
        case myst
    }

    public enum Source: String, Hashable, Codable, Sendable {
        /// In the book's own `.venv` or `node_modules`.
        case project
        /// The app's private installation.
        case managed
        /// Found on the login shell's PATH or in a usual install location.
        case system
        /// A command the user typed.
        case custom
    }

    public var tool: Tool
    public var source: Source
    /// The executable; for a custom command, the command line.
    public var command: String
    /// Folders put in front of PATH, so the tool finds `node` (and Python for execution).
    public var pathDirectories: [String]

    public init(tool: Tool, source: Source, command: String, pathDirectories: [String] = []) {
        self.tool = tool
        self.source = source
        self.command = command
        self.pathDirectories = pathDirectories
    }

    public static func custom(_ command: String) -> Toolchain {
        let words = command.split(separator: " ")
        return Toolchain(tool: words.contains { $0.hasPrefix("jupyter-book") } ? .jupyterBook : .myst, source: .custom, command: command)
    }

    /// For the UI: "jupyter-book in .venv", "myst (/opt/homebrew/bin)", "npx jupyter-book".
    public var displayName: String {
        switch source {
        case .project: return "\(tool.rawValue) in the book’s environment"
        case .managed: return "\(tool.rawValue) (installed by JupyterBookNook)"
        case .system: return "\(tool.rawValue) (\((command as NSString).deletingLastPathComponent))"
        case .custom: return command
        }
    }

    /// The process to start for `arguments`, e.g. `["build", "--html"]`.
    public func invocation(_ arguments: [String]) -> (executable: String, arguments: [String]) {
        switch source {
        case .custom:
            // `exec` keeps the tool in the process group the runner manages.
            let quoted = arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            return ("/bin/sh", ["-c", "exec \(command) \(quoted.joined(separator: " "))"])
        default:
            return (command, arguments)
        }
    }

    /// The environment for the tool: the app's environment with PATH set to `pathDirectories`
    /// followed by `searchPath` (normally the login shell's PATH).
    public func environment(searchPath: [String], base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        var directories: [String] = []
        for directory in pathDirectories + searchPath where !directories.contains(directory) {
            directories.append(directory)
        }
        environment["PATH"] = directories.joined(separator: ":")
        // Tools should not try to open a browser or wait for input.
        environment["BROWSER"] = "none"
        environment["CI"] = environment["CI"] ?? "1"
        return environment
    }

    /// The tool's version, e.g. "v1.11.0", or nil when it does not run.
    public func version(searchPath: [String]) async -> String? {
        let (executable, arguments) = invocation(["--version"])
        guard let output = try? await ProcessRunner.run(executable, arguments, environment: environment(searchPath: searchPath), timeout: 20),
              output.exitCode == 0 else { return nil }
        return output.lines.map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
    }
}

/// Which toolchain to use: chosen globally, optionally overridden per book.
public enum ToolchainChoice: Hashable, Codable, Sendable {
    /// The first one found: the book's environment, then the managed one, then the system;
    /// `myst` before `jupyter-book` in each.
    case automatic
    case managed
    case executable(String)
    case custom(String)
}

/// Finds Jupyter Book installations. An app started from Finder gets a minimal PATH, so the
/// login shell's PATH and the usual install folders are searched too.
public struct ToolchainLocator: Sendable {
    public var searchPath: [String]
    public var managedToolchain: Toolchain?

    public init(searchPath: [String], managedToolchain: Toolchain? = nil) {
        self.searchPath = searchPath
        self.managedToolchain = managedToolchain
    }

    public static var commonDirectories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin",
            "/opt/homebrew/Caskroom/miniconda/base/bin", "\(home)/miniconda3/bin", "\(home)/anaconda3/bin",
            "\(home)/miniforge3/bin", "/usr/bin", "/bin",
        ]
    }

    /// The PATH of the user's login shell, plus the usual install folders.
    public static func defaultSearchPath() async -> [String] {
        var directories: [String] = []
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if let output = try? await ProcessRunner.run(shell, ["-l", "-c", "printenv PATH"], timeout: 5), output.exitCode == 0,
           let path = output.lines.last(where: { $0.contains("/") }) {
            directories = path.split(separator: ":").map(String.init)
        }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + commonDirectories
        where !directories.contains(directory) {
            directories.append(directory)
        }
        return directories
    }

    /// Every toolchain found for a book, best first, without duplicates.
    public func candidates(for projectRoot: URL?) -> [Toolchain] {
        var found: [Toolchain] = []
        var seen = Set<String>()
        func add(_ tool: Toolchain.Tool, at path: String, source: Toolchain.Source, extra: [String] = []) {
            guard FileManager.default.isExecutableFile(atPath: path) else { return }
            let resolved = (path as NSString).resolvingSymlinksInPath
            guard seen.insert(resolved).inserted else { return }
            found.append(Toolchain(tool: tool, source: source, command: path,
                                   pathDirectories: [(path as NSString).deletingLastPathComponent] + extra))
        }
        if let projectRoot {
            for folder in [".venv/bin", "venv/bin", "node_modules/.bin"] {
                for tool in [Toolchain.Tool.myst, .jupyterBook] {
                    add(tool, at: projectRoot.appendingPathComponent(folder).appendingPathComponent(tool.rawValue).path, source: .project)
                }
            }
        }
        if let managedToolchain, FileManager.default.isExecutableFile(atPath: managedToolchain.command) {
            seen.insert((managedToolchain.command as NSString).resolvingSymlinksInPath)
            found.append(managedToolchain)
        }
        for tool in [Toolchain.Tool.myst, .jupyterBook] {
            for directory in searchPath {
                add(tool, at: (directory as NSString).appendingPathComponent(tool.rawValue), source: .system)
            }
        }
        return found
    }

    /// The toolchain `choice` selects, or nil when it is not available.
    public func resolve(_ choice: ToolchainChoice, for projectRoot: URL?) -> Toolchain? {
        let candidates = candidates(for: projectRoot)
        switch choice {
        case .automatic:
            return candidates.first
        case .managed:
            return candidates.first { $0.source == .managed }
        case .executable(let path):
            return candidates.first { $0.command == path }
                ?? (FileManager.default.isExecutableFile(atPath: path)
                    ? Toolchain(tool: path.hasSuffix("myst") ? .myst : .jupyterBook, source: .system, command: path,
                                pathDirectories: [(path as NSString).deletingLastPathComponent])
                    : nil)
        case .custom(let command):
            let trimmed = command.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : .custom(trimmed)
        }
    }
}
