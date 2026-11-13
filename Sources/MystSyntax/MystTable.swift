import Foundation

/// A table of a page as the table assistant edits it: a pipe table (optionally inside a
/// `{table}` directive for its caption and label) or a `{list-table}` directive. Reading and
/// writing it again gives the same table; `markdown` lays a pipe table out in even columns.
public struct MystTable: Equatable, Sendable {
    public enum Format: String, CaseIterable, Sendable {
        /// `| a | b |` rows; always one header row; cells of one line.
        case pipe
        /// `{list-table}`: a list of rows, each a list of cells; cells may have several lines.
        case list
    }

    public enum Alignment: String, CaseIterable, Sendable {
        case none, left, center, right
    }

    /// A directive option the assistant has no field for; written back as it was.
    public struct Option: Equatable, Sendable {
        public var key: String
        public var value: String
        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    public var format: Format
    /// Every row has `columnCount` cells.
    public var rows: [[String]]
    /// Rows at the top that are headers (a pipe table always has one).
    public var headerRows: Int
    /// Per column; pipe tables only.
    public var alignments: [Alignment]
    public var caption = ""
    public var label = ""
    /// `:align:`: where the table sits on the page.
    public var tableAlignment: Alignment = .none
    /// `:class:` (e.g. `full-width`).
    public var className = ""
    /// `:enumerated:`; nil leaves numbering to the book.
    public var enumerated: Bool?
    public var otherOptions: [Option] = []
    /// The directive's fence (`:::` unless the page wrote another).
    public var fence = ":::"
    /// The indentation of the table's lines (inside a list item or directive).
    public var indent = ""

    public init(format: Format = .pipe, rows: [[String]], headerRows: Int = 1, alignments: [Alignment] = []) {
        self.format = format
        self.rows = rows
        self.headerRows = headerRows
        self.alignments = alignments
        normalize()
    }

    /// A new table of empty cells with a header row.
    public static func empty(columns: Int = 3, rows: Int = 3) -> MystTable {
        let header = (1...max(1, columns)).map { "Column \($0)" }
        let body = Array(repeating: Array(repeating: "", count: header.count), count: max(0, rows - 1))
        return MystTable(rows: [header] + body)
    }

    public var columnCount: Int { rows.first?.count ?? 0 }
    public var rowCount: Int { rows.count }

    /// Even rows, alignments for every column, header rows within the table.
    mutating func normalize() {
        let width = max(1, rows.map(\.count).max() ?? 0)
        if rows.isEmpty { rows = [Array(repeating: "", count: width)] }
        rows = rows.map { $0 + Array(repeating: "", count: width - $0.count) }
        alignments = Array(alignments.prefix(width)) + Array(repeating: .none, count: max(0, width - alignments.count))
        headerRows = format == .pipe ? 1 : min(max(0, headerRows), rows.count)
    }

    // MARK: Changing the table

    public mutating func insertRow(at index: Int) {
        let index = min(max(0, index), rows.count)
        rows.insert(Array(repeating: "", count: columnCount), at: index)
        // A row inserted among the header rows is a header row too.
        if format == .list, index < headerRows { headerRows += 1 }
    }

    public mutating func removeRow(at index: Int) {
        guard rows.indices.contains(index), rows.count > 1 else { return }
        rows.remove(at: index)
        if format == .list, index < headerRows { headerRows -= 1 }
        normalize()
    }

    public mutating func moveRow(from source: Int, to destination: Int) {
        guard rows.indices.contains(source), rows.indices.contains(destination), source != destination else { return }
        let row = rows.remove(at: source)
        rows.insert(row, at: destination)
    }

    public mutating func insertColumn(at index: Int) {
        let index = min(max(0, index), columnCount)
        for row in rows.indices { rows[row].insert("", at: index) }
        alignments.insert(.none, at: index)
    }

    public mutating func removeColumn(at index: Int) {
        guard (0..<columnCount).contains(index), columnCount > 1 else { return }
        for row in rows.indices { rows[row].remove(at: index) }
        alignments.remove(at: index)
    }

    public mutating func moveColumn(from source: Int, to destination: Int) {
        let columns = 0..<columnCount
        guard columns.contains(source), columns.contains(destination), source != destination else { return }
        for row in rows.indices {
            let cell = rows[row].remove(at: source)
            rows[row].insert(cell, at: destination)
        }
        let alignment = alignments.remove(at: source)
        alignments.insert(alignment, at: destination)
    }

    /// Changes the format. A pipe table has exactly one header row and cells of one line, so lines
    /// of a cell are joined with spaces.
    public mutating func convert(to newFormat: Format) {
        guard newFormat != format else { return }
        format = newFormat
        if newFormat == .pipe {
            rows = rows.map { $0.map(Self.oneLine) }
        } else {
            headerRows = 1
        }
        normalize()
    }

    /// What converting to a pipe table would lose, for a note in the assistant.
    public var pipeConversionLosses: [String] {
        guard format == .list else { return [] }
        var losses: [String] = []
        if headerRows == 0 { losses.append("The first row becomes the header row.") }
        if headerRows > 1 { losses.append("Only the first row stays a header row.") }
        if rows.joined().contains(where: { $0.contains("\n") }) { losses.append("Cells of several lines are joined into one line.") }
        return losses
    }

    /// A cell's lines joined with spaces.
    public static func oneLine(_ cell: String) -> String {
        cell.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: Writing

    /// Whether a pipe table needs a `{table}` directive around it.
    var needsDirective: Bool {
        format == .list || !caption.isEmpty || !label.isEmpty || tableAlignment != .none || !className.isEmpty || enumerated != nil || !otherOptions.isEmpty
    }

    /// The table's Markdown, without a newline at the end.
    public var markdown: String {
        var lines: [String] = []
        var options: [(String, String)] = []
        if !label.isEmpty { options.append(("label", label)) }
        if format == .list, headerRows > 0 { options.append(("header-rows", "\(headerRows)")) }
        if tableAlignment != .none { options.append(("align", tableAlignment.rawValue)) }
        if !className.isEmpty { options.append(("class", className)) }
        if let enumerated { options.append(("enumerated", enumerated ? "true" : "false")) }
        options += otherOptions.map { ($0.key, $0.value) }
        let wrapped = needsDirective
        if wrapped {
            let name = format == .list ? "list-table" : "table"
            let argument = Self.oneLine(caption)
            lines.append(fence + "{\(name)}" + (argument.isEmpty ? "" : " " + argument))
            for (key, value) in options { lines.append(":\(key):" + (value.isEmpty ? "" : " " + value)) }
            if format == .list { lines.append("") }
        }
        lines += format == .pipe ? pipeLines : listLines
        if wrapped {
            // Without the blank line a pipe table runs on over the closing fence (mystmd 1.11).
            if format == .pipe { lines.append("") }
            lines.append(fence)
        }
        return lines.map { $0.isEmpty ? "" : indent + $0 }.joined(separator: "\n")
    }

    private var pipeLines: [String] {
        let cells = rows.map { $0.map { Self.escapePipes(Self.oneLine($0)) } }
        let widths = (0..<columnCount).map { column in max(3, cells.map { Self.displayWidth($0[column]) }.max() ?? 0) }
        func line(_ row: [String]) -> String {
            let padded = row.enumerated().map { column, cell -> String in
                let space = String(repeating: " ", count: widths[column] - Self.displayWidth(cell))
                switch alignments[column] {
                case .right: return space + cell
                case .center:
                    let left = space.count / 2
                    return String(repeating: " ", count: left) + cell + String(repeating: " ", count: space.count - left)
                default: return cell + space
                }
            }
            return "| " + padded.joined(separator: " | ") + " |"
        }
        let delimiter = alignments.enumerated().map { column, alignment -> String in
            let width = widths[column]
            switch alignment {
            case .none: return String(repeating: "-", count: width)
            case .left: return ":" + String(repeating: "-", count: width - 1)
            case .right: return String(repeating: "-", count: width - 1) + ":"
            case .center: return ":" + String(repeating: "-", count: width - 2) + ":"
            }
        }
        return [line(cells[0]), "| " + delimiter.joined(separator: " | ") + " |"] + cells.dropFirst().map(line)
    }

    private var listLines: [String] {
        var lines: [String] = []
        for row in rows {
            for (column, cell) in row.enumerated() {
                let bullet = column == 0 ? "* - " : "  - "
                let cellLines = cell.components(separatedBy: "\n")
                lines.append((bullet + cellLines[0]).trimmingTrailingSpaces)
                for more in cellLines.dropFirst() { lines.append(more.isEmpty ? "" : "    " + more) }
            }
        }
        return lines
    }

    static func escapePipes(_ cell: String) -> String {
        var result = ""
        var previous: Character?
        for character in cell {
            if character == "|", previous != "\\" { result.append("\\") }
            result.append(character)
            previous = character
        }
        return result
    }

    /// Columns the text takes in a monospaced editor: wide (East Asian) characters count twice.
    static func displayWidth(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { width, scalar in
            let value = scalar.value
            if scalar.properties.generalCategory == .nonspacingMark || (0xFE00...0xFE0F).contains(value) || value == 0x200D { return width }
            let wide = (0x1100...0x115F).contains(value) || (0x2E80...0xA4CF).contains(value) || (0xAC00...0xD7A3).contains(value)
                || (0xF900...0xFAFF).contains(value) || (0xFF00...0xFF60).contains(value) || (0x1F300...0x1FAFF).contains(value)
            return width + (wide ? 2 : 1)
        }
    }
}

/// A table found in a page.
public struct MystTableBlock: Equatable, Sendable {
    /// From the first line of the table (or its directive) to the end of its last line, without the newline.
    public var range: NSRange
    public var table: MystTable
}

public enum MystTables {
    /// Every table in `text`, in page order: pipe tables (with their `{table}` directive when they are
    /// all it holds) and list tables. Tables in code blocks and in front matter are not tables.
    public static func all(in text: String) -> [MystTableBlock] {
        let ns = text as NSString
        let lines = Self.lines(of: ns)
        var found: [MystTableBlock] = []
        var index = 0
        // Front matter.
        if lines.first.map({ ns.substring(with: $0.content) == "---" }) == true {
            index = 1
            while index < lines.count, ns.substring(with: lines[index].content) != "---" { index += 1 }
            index += 1
        }
        // Fences of the directives the scan is inside (their Markdown may hold tables).
        var openFences: [String] = []
        while index < lines.count {
            let trimmed = ns.substring(with: lines[index].content).trimmingCharacters(in: .whitespaces)
            if let fence = Self.fence(of: trimmed) {
                if Self.isBareFence(trimmed), let inner = openFences.last, trimmed.first == inner.first, trimmed.count >= inner.count {
                    openFences.removeLast()
                    index += 1
                    continue
                }
                let close = Self.closingLine(for: fence, after: index, lines: lines, in: ns)
                let name = Self.directiveName(trimmed)
                if name == "list-table", let block = listTable(lines: lines, open: index, close: close, in: ns) {
                    found.append(block)
                    index = close + 1
                    continue
                }
                if name == "table", let block = wrappedPipeTable(lines: lines, open: index, close: close, in: ns) {
                    found.append(block)
                    index = close + 1
                    continue
                }
                // Code, math and other literal blocks: their content is skipped.
                guard let name, !Self.literalDirectives.contains(name) else {
                    index = close + 1
                    continue
                }
                openFences.append(fence)
                index += 1
                continue
            }
            if let (table, last) = pipeTable(lines: lines, at: index, in: ns) {
                let range = NSRange(location: lines[index].content.location, length: NSMaxRange(lines[last].content) - lines[index].content.location)
                found.append(MystTableBlock(range: range, table: table))
                index = last + 1
                continue
            }
            index += 1
        }
        return found
    }

    /// The table that `location` is in (or on the first line of).
    public static func table(at location: Int, in text: String) -> MystTableBlock? {
        all(in: text).first { $0.range.location <= location && location <= NSMaxRange($0.range) }
    }

    static let literalDirectives: Set<String> = [
        "code", "code-block", "code-cell", "sourcecode", "literalinclude", "math", "mermaid", "raw", "csv-table", "include",
    ]

    struct Line {
        /// Without the newline.
        var content: NSRange
    }

    static func lines(of ns: NSString) -> [Line] {
        var lines: [Line] = []
        var location = 0
        while location < ns.length {
            var end = 0, contentsEnd = 0
            ns.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            lines.append(Line(content: NSRange(location: location, length: contentsEnd - location)))
            location = end
        }
        if ns.length == 0 || ns.character(at: ns.length - 1) == 10 { lines.append(Line(content: NSRange(location: ns.length, length: 0))) }
        return lines
    }

    /// The fence a line opens with (```` ``` ````, `~~~`, `:::`…), if it is one.
    static func fence(of trimmed: String) -> String? {
        for mark in ["`", "~", ":"] {
            let run = trimmed.prefix { String($0) == mark }
            if run.count >= 3 { return String(run) }
        }
        return nil
    }

    static func directiveName(_ trimmed: String) -> String? {
        let afterFence = trimmed.drop { $0 == "`" || $0 == ":" || $0 == "~" }
        guard afterFence.first == "{", let close = afterFence.firstIndex(of: "}") else { return nil }
        return String(afterFence[afterFence.index(after: afterFence.startIndex)..<close])
    }

    /// Whether a line is only a fence (a closing fence, or a code fence without info).
    static func isBareFence(_ trimmed: String) -> Bool {
        guard let first = trimmed.first else { return false }
        return fence(of: trimmed) != nil && trimmed.allSatisfy { $0 == first }
    }

    /// The line that closes a block opened with `fence` on line `open` (the last line when unclosed).
    static func closingLine(for fence: String, after open: Int, lines: [Line], in ns: NSString) -> Int {
        for index in (open + 1)..<max(open + 1, lines.count) {
            let trimmed = ns.substring(with: lines[index].content).trimmingCharacters(in: .whitespaces)
            if isBareFence(trimmed), trimmed.first == fence.first, trimmed.count >= fence.count { return index }
        }
        return lines.count - 1
    }

    // MARK: Pipe tables

    /// The cells of a table row: split at pipes that are not escaped, outer pipes dropped.
    static func cells(of line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in line {
            if escaped {
                // `\|` is a pipe in the cell; other escapes stay as written.
                if character != "|" { current.append("\\") }
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|"), cells.count > 1 { cells.removeFirst() }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|"), cells.count > 1 { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func alignments(ofDelimiter line: String) -> [MystTable.Alignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") || trimmed.contains("-") else { return nil }
        let parts = cells(of: trimmed)
        var result: [MystTable.Alignment] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0 == "-" || $0 == ":" }), part.contains("-") else { return nil }
            let core = part.dropFirst(part.hasPrefix(":") ? 1 : 0).dropLast(part.hasSuffix(":") && part.count > 1 ? 1 : 0)
            guard core.allSatisfy({ $0 == "-" }) else { return nil }
            switch (part.hasPrefix(":"), part.hasSuffix(":") && part.count > 1) {
            case (true, true): result.append(.center)
            case (true, false): result.append(.left)
            case (false, true): result.append(.right)
            case (false, false): result.append(.none)
            }
        }
        // A delimiter row of one column needs a pipe (`---` alone is a thematic break or setext underline).
        if parts.count == 1, !trimmed.contains("|") { return nil }
        return result
    }

    /// A pipe table whose header is line `index`, and its last line.
    static func pipeTable(lines: [Line], at index: Int, in ns: NSString) -> (MystTable, Int)? {
        guard index + 1 < lines.count else { return nil }
        let header = ns.substring(with: lines[index].content)
        guard header.contains("|"), let alignments = alignments(ofDelimiter: ns.substring(with: lines[index + 1].content)) else { return nil }
        let headerCells = cells(of: header)
        guard headerCells.count == alignments.count else { return nil }
        var rows = [headerCells]
        var last = index + 1
        while last + 1 < lines.count {
            let line = ns.substring(with: lines[last + 1].content)
            guard line.contains("|"), !line.trimmingCharacters(in: .whitespaces).isEmpty else { break }
            rows.append(cells(of: line))
            last += 1
        }
        var table = MystTable(format: .pipe, rows: rows, headerRows: 1, alignments: alignments)
        table.indent = String(header.prefix { $0 == " " || $0 == "\t" })
        return (table, last)
    }

    /// Options at the top of a directive's body (`:key: value` lines), and the first line after them.
    static func options(lines: [Line], after open: Int, close: Int, in ns: NSString) -> ([MystTable.Option], Int) {
        var options: [MystTable.Option] = []
        var index = open + 1
        while index < close {
            let trimmed = ns.substring(with: lines[index].content).trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(":"), let end = trimmed.dropFirst().firstIndex(of: ":") else { break }
            let key = String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
            guard !key.isEmpty, !key.contains(" ") else { break }
            let value = trimmed[trimmed.index(after: end)...].trimmingCharacters(in: .whitespaces)
            options.append(MystTable.Option(key: key, value: value))
            index += 1
        }
        return (options, index)
    }

    /// Takes the options the assistant has fields for into `table`; keeps the others.
    static func apply(_ options: [MystTable.Option], to table: inout MystTable) {
        for option in options {
            switch option.key {
            case "label", "name": table.label = option.value
            case "header-rows": table.headerRows = Int(option.value) ?? 0
            case "align": table.tableAlignment = MystTable.Alignment(rawValue: option.value) ?? .none
            case "class": table.className = option.value
            case "enumerated":
                let value = option.value.lowercased()
                table.enumerated = value.isEmpty || value == "true" || value == "yes"
            default: table.otherOptions.append(option)
            }
        }
        table.normalize()
    }

    static func directiveParts(_ lines: [Line], _ open: Int, in ns: NSString) -> (indent: String, fence: String, argument: String) {
        let line = ns.substring(with: lines[open].content)
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let fence = fence(of: trimmed) ?? ":::"
        let argument = trimmed.firstIndex(of: "}").map { trimmed[trimmed.index(after: $0)...].trimmingCharacters(in: .whitespaces) } ?? ""
        return (indent, fence, argument)
    }

    /// A `{table}` directive that holds just a pipe table.
    static func wrappedPipeTable(lines: [Line], open: Int, close: Int, in ns: NSString) -> MystTableBlock? {
        guard close > open else { return nil }
        let (options, start) = options(lines: lines, after: open, close: close, in: ns)
        var first = start
        while first < close, ns.substring(with: lines[first].content).trimmingCharacters(in: .whitespaces).isEmpty { first += 1 }
        guard first < close, var (table, last) = pipeTable(lines: lines, at: first, in: ns), last < close else { return nil }
        for line in (last + 1)..<close where !ns.substring(with: lines[line].content).trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        let parts = directiveParts(lines, open, in: ns)
        table.indent = parts.indent
        table.fence = parts.fence
        table.caption = parts.argument
        apply(options, to: &table)
        let range = NSRange(location: lines[open].content.location, length: NSMaxRange(lines[close].content) - lines[open].content.location)
        return MystTableBlock(range: range, table: table)
    }

    /// A `{list-table}` directive: `* - cell` starts a row, `  - cell` the next cell of it, and
    /// lines indented further continue the cell.
    static func listTable(lines: [Line], open: Int, close: Int, in ns: NSString) -> MystTableBlock? {
        guard close > open else { return nil }
        let (options, start) = options(lines: lines, after: open, close: close, in: ns)
        var rows: [[String]] = []
        var cellIndent = 0
        var blankLines = 0
        func bullet(_ text: Substring) -> Substring? {
            guard let first = text.first, "*-+".contains(first) else { return nil }
            let rest = text.dropFirst()
            if rest.isEmpty { return rest }
            guard rest.first == " " else { return nil }
            return rest.drop { $0 == " " }
        }
        func appendToCell(_ text: String) {
            guard !rows.isEmpty, !rows[rows.count - 1].isEmpty else { return }
            let column = rows[rows.count - 1].count - 1
            rows[rows.count - 1][column] += String(repeating: "\n", count: blankLines) + "\n" + text
            blankLines = 0
        }
        for index in start..<close {
            let line = ns.substring(with: lines[index].content)
            let leading = line.prefix { $0 == " " }.count
            let text = line.dropFirst(leading)
            if text.isEmpty {
                if !rows.isEmpty { blankLines += 1 }
                continue
            }
            if let rowRest = bullet(text), rows.isEmpty || leading < cellIndent {
                // A new row; its first cell may be on the same line.
                rows.append([])
                blankLines = 0
                if let cellRest = bullet(rowRest) {
                    cellIndent = leading + (text.count - rowRest.count)
                    rows[rows.count - 1].append(String(cellRest))
                }
                continue
            }
            if let cellRest = bullet(text), !rows.isEmpty, leading >= cellIndent - 2, leading <= cellIndent + 1 || rows[rows.count - 1].isEmpty {
                if rows[rows.count - 1].isEmpty { cellIndent = leading }
                rows[rows.count - 1].append(String(cellRest))
                blankLines = 0
                continue
            }
            // Continuation of the cell: drop the cell's content indentation.
            let contentIndent = cellIndent + 2
            appendToCell(String(line.dropFirst(min(leading, contentIndent))))
        }
        guard !rows.isEmpty, rows.contains(where: { !$0.isEmpty }) else { return nil }
        var table = MystTable(format: .list, rows: rows, headerRows: 0)
        let parts = directiveParts(lines, open, in: ns)
        table.indent = parts.indent
        table.fence = parts.fence
        table.caption = parts.argument
        apply(options, to: &table)
        let range = NSRange(location: lines[open].content.location, length: NSMaxRange(lines[close].content) - lines[open].content.location)
        return MystTableBlock(range: range, table: table)
    }
}

private extension String {
    var trimmingTrailingSpaces: String {
        var result = self
        while result.last == " " { result.removeLast() }
        return result
    }
}
