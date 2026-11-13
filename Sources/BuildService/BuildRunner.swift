import Foundation

/// The outcome of `build --html`.
public struct BuildResult: Sendable {
    public var exitCode: Int32
    public var messages: [BuildMessage]
    public var log: [String]
    public var duration: TimeInterval
    /// `_build/html` in the book folder (`_build/exports` for documents).
    public var outputFolder: URL

    public var succeeded: Bool { exitCode == 0 }
}

/// Options of `build --html` (and of the preview, for `execute`).
public struct BuildOptions: Equatable, Sendable {
    /// Runs the notebooks' code (`--execute`); needs Jupyter in the environment.
    public var execute = false
    /// Exits with an error when there are warnings (`--strict`).
    public var strict = false
    /// The path the site is served under, e.g. `/optimisation-notes/` for GitHub Pages (`BASE_URL`).
    public var baseURL = ""
    /// Build these document exports (e.g. `--pdf`, `--docx`) instead of the HTML site.
    public var documentFlags: [String] = []

    public init(execute: Bool = false, strict: Bool = false, baseURL: String = "", documentFlags: [String] = []) {
        self.execute = execute
        self.strict = strict
        self.baseURL = baseURL
        self.documentFlags = documentFlags
    }

    public var arguments: [String] {
        let what = documentFlags.isEmpty ? ["--html"] : documentFlags
        return ["build"] + what + (execute ? ["--execute"] : []) + (strict ? ["--strict"] : [])
    }

    /// `BASE_URL` without a trailing slash, as MyST expects; nil when empty.
    public var baseURLEnvironment: String? {
        var path = baseURL.trimmingCharacters(in: .whitespaces)
        while path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty else { return nil }
        return path.hasPrefix("/") || path.contains("://") ? path : "/" + path
    }
}

public enum BuildRunner {
    /// Runs `build --html` in `projectRoot`. `onLine` receives the log as it is written.
    public static func buildHTML(
        projectRoot: URL,
        toolchain: Toolchain,
        searchPath: [String],
        options: BuildOptions = BuildOptions(),
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> BuildResult {
        let start = Date()
        let (executable, arguments) = toolchain.invocation(options.arguments)
        var environment = toolchain.environment(searchPath: searchPath)
        if let base = options.baseURLEnvironment { environment["BASE_URL"] = base }
        let output = try await ProcessRunner.run(
            executable, arguments, environment: environment, in: projectRoot, onLine: onLine
        )
        var parser = BuildLogParser()
        output.lines.forEach { parser.consume($0) }
        return BuildResult(
            exitCode: output.exitCode, messages: parser.messages, log: output.lines,
            duration: Date().timeIntervalSince(start),
            outputFolder: projectRoot.appendingPathComponent(options.documentFlags.isEmpty ? "_build/html" : "_build/exports", isDirectory: true)
        )
    }
}

/// `myst start` running in the background: the live preview of a book.
/// The tool watches the files and rebuilds changed pages itself; the site reloads in the browser.
public final class PreviewServer: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case starting
        case running(URL)
        case failed(String)
        case stopped
    }

    private let lock = NSLock()
    private var process: ManagedProcess?
    private var parser = BuildLogParser()
    private var log: [String] = []
    private var _state: State = .stopped
    /// Counts starts. Output and exit of an earlier server (still shutting down after a restart)
    /// must not change the state of the current one.
    private var generation = 0

    public init() {}

    public var state: State { lock.withLock { _state } }
    /// The port of MyST's content server, whose WebSocket announces changed pages.
    public var contentPort: Int? { lock.withLock { _contentPort } }
    private var _contentPort: Int?
    public var messages: [BuildMessage] { lock.withLock { parser.messages } }
    public var recentLog: [String] { lock.withLock { Array(log.suffix(400)) } }

    /// Starts the server on free ports. `onChange` is called (on a background thread) whenever
    /// the state or the messages change.
    public func start(
        projectRoot: URL,
        toolchain: Toolchain,
        searchPath: [String],
        execute: Bool = false,
        onChange: @escaping @Sendable () -> Void
    ) throws {
        stop()
        let appPort = try FreePort.find()
        let contentPort = try FreePort.find(excluding: [appPort])
        let (executable, arguments) = toolchain.invocation(
            ["start", "--port", String(appPort), "--server-port", String(contentPort)] + (execute ? ["--execute"] : [])
        )
        let current: Int = lock.withLock {
            generation += 1
            _state = .starting
            _contentPort = contentPort
            parser = BuildLogParser()
            log = []
            return generation
        }
        onChange()
        let process = try ManagedProcess(
            executable: executable, arguments: arguments,
            environment: toolchain.environment(searchPath: searchPath), workingDirectory: projectRoot,
            onLine: { [weak self] line in
                guard let self else { return }
                let changed: Bool = self.lock.withLock {
                    guard self.generation == current else { return false }
                    self.log.append(line)
                    let before = self.parser.messages.count
                    // Rebuilds after a save repeat earlier messages; the parser drops repeats.
                    self.parser.consume(line)
                    var changed = self.parser.messages.count != before
                    if case .starting = self._state, line.contains("Server started on port") {
                        self._state = .running(URL(string: "http://localhost:\(appPort)/")!)
                        changed = true
                    }
                    return changed
                }
                if changed { onChange() }
            },
            onExit: { [weak self] code in
                guard let self else { return }
                let isCurrent: Bool = self.lock.withLock {
                    guard self.generation == current else { return false }
                    if case .stopped = self._state { return false }
                    let tail = self.log.suffix(6).joined(separator: "\n")
                    self._state = .failed("The preview server stopped (exit code \(code)).\n\(tail)")
                    return true
                }
                if isCurrent { onChange() }
            }
        )
        lock.withLock { self.process = process }
    }

    public func stop() {
        let process: ManagedProcess? = lock.withLock {
            _state = .stopped
            defer { self.process = nil }
            return self.process
        }
        process?.terminate()
    }

    /// For app termination: signal the server group without waiting.
    public func stopNow() {
        lock.withLock { process }?.terminateNow()
    }

    deinit {
        process?.terminateNow()
    }
}

/// Finds a free TCP port on the loopback interface by letting the system pick one.
public enum FreePort {
    public static func find(excluding: Set<Int> = []) throws -> Int {
        for _ in 0..<20 {
            let socketFD = socket(AF_INET, SOCK_STREAM, 0)
            guard socketFD >= 0 else { break }
            defer { close(socketFD) }
            var address = sockaddr_in()
            #if canImport(Darwin)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic -> Bool in
                    bind(socketFD, generic, length) == 0 && getsockname(socketFD, generic, &length) == 0
                }
            }
            guard bound else { continue }
            let port = Int(UInt16(bigEndian: address.sin_port))
            if !excluding.contains(port) { return port }
        }
        throw ProcessRunnerError.spawnFailed("a free port", errno)
    }
}
