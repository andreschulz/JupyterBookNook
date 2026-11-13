import Foundation

/// Converts PDF figures to SVG for the web, with `pdf2svg` or `pdftocairo` (Poppler) when one
/// is installed. MyST itself turns PDF figures into PNG; an SVG next to the PDF stays sharp, and
/// a figure written as `name.*` lets MyST use the SVG for the site and the PDF for LaTeX.
public enum FigureConverter {
    public enum Tool: Equatable, Sendable {
        case pdf2svg(String)
        case pdftocairo(String)
    }

    /// The first converter found in `searchPath`.
    public static func findTool(searchPath: [String]) -> Tool? {
        let fm = FileManager.default
        for directory in searchPath {
            let pdf2svg = (directory as NSString).appendingPathComponent("pdf2svg")
            if fm.isExecutableFile(atPath: pdf2svg) { return .pdf2svg(pdf2svg) }
        }
        for directory in searchPath {
            let cairo = (directory as NSString).appendingPathComponent("pdftocairo")
            if fm.isExecutableFile(atPath: cairo) { return .pdftocairo(cairo) }
        }
        return nil
    }

    /// The first page of the PDF at `input` as SVG data.
    public static func svg(fromPDF input: URL, tool: Tool) async throws -> Data {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("nook-\(UUID().uuidString).svg")
        defer { try? FileManager.default.removeItem(at: output) }
        let result: ProcessRunner.Output
        switch tool {
        case .pdf2svg(let path):
            result = try await ProcessRunner.run(path, [input.path, output.path, "1"], timeout: 60)
        case .pdftocairo(let path):
            result = try await ProcessRunner.run(path, ["-svg", "-f", "1", "-l", "1", input.path, output.path], timeout: 60)
        }
        guard result.exitCode == 0, let data = try? Data(contentsOf: output), !data.isEmpty else {
            throw ConversionError.failed(result.lines.joined(separator: "\n"))
        }
        return data
    }

    public enum ConversionError: LocalizedError {
        case failed(String)

        public var errorDescription: String? {
            if case .failed(let log) = self { return "The PDF figure could not be converted to SVG.\n\(log)" }
            return nil
        }
    }
}
