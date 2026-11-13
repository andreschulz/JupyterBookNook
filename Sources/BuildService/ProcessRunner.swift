import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum ProcessRunnerError: LocalizedError, Equatable {
    case spawnFailed(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .spawnFailed(let executable, let code):
            return "Could not start \(executable): \(String(cString: strerror(code)))."
        }
    }
}

/// A child process in its own process group, with stdout and stderr merged and delivered line by line.
///
/// Build tools start helper processes (`myst start` runs the theme's web server as a child), so
/// stopping only the direct child would leave servers running. Every signal goes to the whole group,
/// and the group is cleaned up when the main process exits.
public final class ManagedProcess: @unchecked Sendable {
    public let pid: pid_t
    private let lock = NSLock()
    private var exitCode: Int32?

    /// Starts `executable`. `onLine` is called on a background thread for each line of output;
    /// `onExit` once, after the last line, with the exit code (128 + signal number if killed).
    public init(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        onLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw ProcessRunnerError.spawnFailed(executable, errno) }
        let (readEnd, writeEnd) = (fds[0], fds[1])

        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 2)
        posix_spawn_file_actions_addclose(&actions, readEnd)
        posix_spawn_file_actions_addclose(&actions, writeEnd)
        posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path)
        // The child gets default signal handling and an empty signal mask. Otherwise it inherits
        // the parent's ignored or blocked signals, and SIGTERM would not stop it.
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var flags = Int32(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        #if canImport(Darwin)
        flags |= Int32(POSIX_SPAWN_CLOEXEC_DEFAULT) // no other descriptors leak into the child
        #endif
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        close(writeEnd)
        guard result == 0 else {
            close(readEnd)
            throw ProcessRunnerError.spawnFailed(executable, result)
        }
        self.pid = pid

        let readerDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            Self.readLines(from: readEnd, onLine: onLine)
            close(readEnd)
            readerDone.signal()
        }
        Thread.detachNewThread { [self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            lock.withLock { exitCode = code }
            // Helpers left behind by the tool would keep the pipe open and keep running.
            kill(-pid, SIGTERM)
            _ = readerDone.wait(timeout: .now() + 3)
            onExit(code)
        }
    }

    public var isRunning: Bool { lock.withLock { exitCode == nil } }

    /// Asks the whole process group to stop, and kills it if it is still running after `grace` seconds.
    public func terminate(grace: TimeInterval = 3) {
        guard isRunning else { return }
        kill(-pid, SIGTERM)
        let pid = pid
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [weak self] in
            if self?.isRunning ?? false { kill(-pid, SIGKILL) }
        }
    }

    /// Stops the group immediately; for app termination, where there is no time to wait.
    public func terminateNow() {
        kill(-pid, SIGTERM)
    }

    private static func readLines(from fd: Int32, onLine: (String) -> Void) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            pending.append(contentsOf: buffer[0..<count])
            while let newline = pending.firstIndex(of: 10) {
                let lineData = pending[pending.startIndex..<newline]
                onLine(String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
                pending.removeSubrange(pending.startIndex...newline)
            }
        }
        if !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
    }
}

/// Runs a command to completion and collects its output.
public enum ProcessRunner {
    public struct Output: Sendable {
        public var exitCode: Int32
        public var lines: [String]
    }

    public static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        in directory: URL = URL(fileURLWithPath: NSTemporaryDirectory()),
        timeout: TimeInterval? = nil,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Output {
        let collected = LineCollector()
        let running = ProcessBox()
        // Cancelling the task stops the process group; the call then returns its exit code.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
            do {
                let process = try ManagedProcess(
                    executable: executable, arguments: arguments, environment: environment, workingDirectory: directory,
                    onLine: { line in
                        collected.append(line)
                        onLine?(line)
                    },
                    onExit: { code in continuation.resume(returning: Output(exitCode: code, lines: collected.lines)) }
                )
                running.set(process)
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { process.terminate(grace: 1) }
                }
            } catch {
                continuation.resume(throwing: error)
            }
            }
        } onCancel: {
            running.terminate()
        }
    }
}

/// The process of a `run` call, for cancellation (which may come before the process exists).
final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: ManagedProcess?
    private var cancelled = false

    func set(_ process: ManagedProcess) {
        let stop = lock.withLock {
            self.process = process
            return cancelled
        }
        if stop { process.terminate(grace: 2) }
    }

    func terminate() {
        let process = lock.withLock {
            cancelled = true
            return self.process
        }
        process?.terminate(grace: 2)
    }
}

final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) { lock.withLock { storage.append(line) } }
    var lines: [String] { lock.withLock { storage } }
}
