#if os(macOS)
import CryptoKit
import Foundation

/// The app's private copy of Node.js and MyST (`mystmd`, the engine of Jupyter Book 2) in Application Support: nothing is installed
/// system-wide, no Terminal is needed, and removing it deletes one folder.
public struct ManagedToolchain: Sendable {
    public static let nodeVersion = "v24.22.0"
    public static let mystVersion = "1.11.0"

    public let root: URL

    public init(root: URL = ManagedToolchain.defaultRoot) {
        self.root = root
    }

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JupyterBookNook/toolchain", isDirectory: true)
    }

    var nodeBin: URL { root.appendingPathComponent("node/bin", isDirectory: true) }
    var executable: URL { root.appendingPathComponent("mystmd/node_modules/.bin/myst") }

    public var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: executable.path)
            && FileManager.default.isExecutableFile(atPath: nodeBin.appendingPathComponent("node").path)
    }

    public var toolchain: Toolchain {
        Toolchain(tool: .myst, source: .managed, command: executable.path, pathDirectories: [nodeBin.path])
    }

    /// Versions recorded at install time.
    public var installedVersions: (node: String, myst: String)? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("versions.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let node = object["node"], let myst = object["mystmd"] else { return nil }
        return (node, myst)
    }

    public enum Step: Sendable, Equatable {
        case downloadingNode(fraction: Double)
        case verifying
        case unpacking
        case installingMyst
        case done
    }

    public enum InstallError: LocalizedError {
        case download(String)
        case checksumMismatch
        case step(String, [String])

        public var errorDescription: String? {
            switch self {
            case .download(let reason): return "Downloading Node.js failed: \(reason)"
            case .checksumMismatch: return "The downloaded Node.js does not match its published checksum, so it was not installed."
            case .step(let what, let log): return "\(what) failed.\n" + log.suffix(8).joined(separator: "\n")
            }
        }
    }

    /// Downloads Node.js (checked against nodejs.org's SHA-256 list) and installs the pinned
    /// `mystmd` with its npm. Installs into a staging folder first, so a failed install
    /// leaves any previous one intact.
    public func install(progress: @escaping @Sendable (Step) -> Void) async throws {
        let fileManager = FileManager.default
        let staging = root.deletingLastPathComponent().appendingPathComponent("toolchain-staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x64"
        #endif
        let name = "node-\(Self.nodeVersion)-darwin-\(arch)"
        let base = URL(string: "https://nodejs.org/dist/\(Self.nodeVersion)/")!

        progress(.downloadingNode(fraction: 0))
        let archive = staging.appendingPathComponent("\(name).tar.gz")
        try await download(base.appendingPathComponent("\(name).tar.gz"), to: archive) { progress(.downloadingNode(fraction: $0)) }

        progress(.verifying)
        let (sums, _) = try await URLSession.shared.data(from: base.appendingPathComponent("SHASUMS256.txt"))
        let expected = String(decoding: sums, as: UTF8.self).split(separator: "\n")
            .first { $0.hasSuffix("  \(name).tar.gz") }?.split(separator: " ").first.map(String.init)
        let actual = try SHA256.hash(data: Data(contentsOf: archive, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()
        guard let expected, expected == actual else { throw InstallError.checksumMismatch }

        progress(.unpacking)
        let unpacked = try await ProcessRunner.run("/usr/bin/tar", ["-xzf", archive.path, "-C", staging.path])
        guard unpacked.exitCode == 0 else { throw InstallError.step("Unpacking Node.js", unpacked.lines) }
        try fileManager.moveItem(at: staging.appendingPathComponent(name), to: staging.appendingPathComponent("node"))
        try fileManager.removeItem(at: archive)

        progress(.installingMyst)
        let stagedNodeBin = staging.appendingPathComponent("node/bin")
        let prefix = staging.appendingPathComponent("mystmd")
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(stagedNodeBin.path):/usr/bin:/bin"
        environment["npm_config_update_notifier"] = "false"
        let npm = try await ProcessRunner.run(
            stagedNodeBin.appendingPathComponent("npm").path,
            ["install", "--prefix", prefix.path, "--no-audit", "--no-fund", "mystmd@\(Self.mystVersion)"],
            environment: environment, in: staging
        )
        guard npm.exitCode == 0 else { throw InstallError.step("Installing MyST with npm", npm.lines) }

        let versions = ["node": Self.nodeVersion, "mystmd": Self.mystVersion]
        try JSONSerialization.data(withJSONObject: versions, options: [.prettyPrinted, .sortedKeys])
            .write(to: staging.appendingPathComponent("versions.json"))

        // Swap the new installation in.
        try fileManager.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = root.deletingLastPathComponent().appendingPathComponent("toolchain-old-\(UUID().uuidString)")
        if fileManager.fileExists(atPath: root.path) { try fileManager.moveItem(at: root, to: old) }
        try fileManager.moveItem(at: staging, to: root)
        try? fileManager.removeItem(at: old)
        progress(.done)
    }

    public func remove() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    private func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw InstallError.download("the server answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let expected = Double(max(response.expectedContentLength, 1))
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var written = 0.0
        var lastReported = 0.0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                written += Double(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if written / expected - lastReported > 0.02 {
                    lastReported = written / expected
                    progress(min(lastReported, 1))
                }
            }
        }
        try handle.write(contentsOf: buffer)
        progress(1)
    }
}
#endif
