import AppKit
import MystSyntax
import SwiftUI

/// The table assistant (the pink “TA” circle next to a table, or Format › Table Assistant…): the
/// table as a grid of cells to edit, rows and columns to add, move and delete (after asking), and
/// the table's caption, label, format and alignment. The page changes only on Apply, as one undo step.
struct TableAssistantView: View {
    let request: TableAssistantRequest
    let apply: (MystTable) -> Void
    let showTableStyle: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var table: MystTable
    /// The cell the row and column buttons act on: the one last clicked or typed in.
    @State private var current: Cell
    @FocusState private var focused: Cell?
    @State private var pendingDeletion: Deletion?
    @AppStorage("tableAssistant.showsMarkdown") private var showsMarkdown = false

    struct Cell: Hashable {
        var row: Int
        var column: Int
    }

    enum Deletion: Identifiable {
        case row(Int), column(Int)
        var id: String {
            switch self {
            case .row(let index): "row\(index)"
            case .column(let index): "column\(index)"
            }
        }
    }

    init(request: TableAssistantRequest, apply: @escaping (MystTable) -> Void, showTableStyle: @escaping () -> Void) {
        self.request = request
        self.apply = apply
        self.showTableStyle = showTableStyle
        _table = State(initialValue: request.table)
        _current = State(initialValue: Cell(row: request.table.rowCount > 1 ? 1 : 0, column: 0))
    }

    static let cellWidth: CGFloat = 150
    static let rowHeaderWidth: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    toolbar
                    Divider()
                    grid
                }
                Divider()
                settings
                    .frame(width: 270)
            }
            if showsMarkdown {
                Divider()
                GeometryReader { geometry in
                    ScrollView([.vertical, .horizontal]) {
                        Text(table.markdown)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                    }
                }
                .frame(height: 150)
                .background(Color(nsColor: .textBackgroundColor))
            }
            Divider()
            footer
        }
        .frame(minWidth: 860, idealWidth: 980, minHeight: 520, idealHeight: 620)
        .onChange(of: focused) { _, cell in if let cell { current = cell } }
        .alert(deletionTitle, isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
               presenting: pendingDeletion) { deletion in
            Button("Delete", role: .destructive) { delete(deletion) }
            Button("Cancel", role: .cancel) {}
        } message: { deletion in
            Text(deletionMessage(deletion))
        }
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 10) {
            TableAssistantBadge(size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.isNew ? "New Table" : "Table Assistant").font(.headline)
                Text("\(table.format == .pipe ? "Pipe table" : "List table") · \(table.rowCount) × \(table.columnCount) · \(request.path), line \(request.line)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Toggle(isOn: $showsMarkdown) { Label("Markdown", systemImage: "chevron.left.forwardslash.chevron.right") }
                .toggleStyle(.button)
                .help("Show the table’s Markdown as it will be written")
            Text(table.format == .list ? "⇥ next cell · ⌥↩ new line in a cell" : "⇥ next cell · ↩ cell below")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(request.isNew ? "Insert Table" : "Apply") { apply(table) }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .help(request.isNew ? "Insert the table at the cursor (⌘↩)" : "Write the table into the page (⌘↩)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Rows and columns

    private var toolbar: some View {
        HStack(spacing: 14) {
            Button { insertRow(at: current.row) } label: { Label("Row Above", systemImage: "arrow.up.to.line") }
            Button { insertRow(at: current.row + 1) } label: { Label("Row Below", systemImage: "arrow.down.to.line") }
            Button { insertColumn(at: current.column) } label: { Label("Column Left", systemImage: "arrow.left.to.line") }
            Button { insertColumn(at: current.column + 1) } label: { Label("Column Right", systemImage: "arrow.right.to.line") }
            Divider().frame(height: 16)
            Button(role: .destructive) { pendingDeletion = .row(current.row) } label: { Label("Delete Row", systemImage: "minus.rectangle") }
                .disabled(table.rowCount < 2)
            Button(role: .destructive) { pendingDeletion = .column(current.column) } label: { Label("Delete Column", systemImage: "minus.rectangle.portrait") }
                .disabled(table.columnCount < 2)
            Spacer()
            Text("Cell \(Self.columnName(current.column))\(current.row + 1)")
                .layoutPriority(-1)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var grid: some View {
        GeometryReader { geometry in
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    Color.clear.frame(width: Self.rowHeaderWidth, height: 26)
                    ForEach(0..<table.columnCount, id: \.self) { column in columnHeader(column) }
                    addButton("Add a column at the right", systemImage: "plus") { insertColumn(at: table.columnCount) }
                }
                ForEach(0..<table.rowCount, id: \.self) { row in
                    GridRow {
                        rowHeader(row)
                        ForEach(0..<table.columnCount, id: \.self) { column in cellField(Cell(row: row, column: column)) }
                    }
                }
                GridRow {
                    addButton("Add a row at the bottom", systemImage: "plus") { insertRow(at: table.rowCount) }
                        .frame(width: Self.rowHeaderWidth)
                }
            }
            .fixedSize()
            .padding(14)
            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
        }
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
    }

    private func addButton(_ help: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    static func columnName(_ index: Int) -> String {
        var name = ""
        var value = index + 1
        while value > 0 {
            let remainder = (value - 1) % 26
            name = String(UnicodeScalar(65 + remainder)!) + name
            value = (value - 1) / 26
        }
        return name
    }

    private func columnHeader(_ column: Int) -> some View {
        Menu {
            if table.format == .pipe {
                Picker("Text Alignment", selection: alignmentBinding(column)) {
                    ForEach(MystTable.Alignment.allCases, id: \.self) { Text(Self.alignmentName($0)).tag($0) }
                }
                Divider()
            }
            Button("Insert Column Left") { insertColumn(at: column) }
            Button("Insert Column Right") { insertColumn(at: column + 1) }
            Button("Move Left") { moveColumn(column, by: -1) }.disabled(column == 0)
            Button("Move Right") { moveColumn(column, by: 1) }.disabled(column == table.columnCount - 1)
            Divider()
            Button("Delete Column…", role: .destructive) { pendingDeletion = .column(column) }.disabled(table.columnCount < 2)
        } label: {
            HStack(spacing: 4) {
                Text(Self.columnName(column)).fontWeight(.medium)
                if table.format == .pipe, column < table.alignments.count, table.alignments[column] != .none {
                    Image(systemName: Self.alignmentSymbol(table.alignments[column])).imageScale(.small)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .foregroundStyle(current.column == column ? Color.accentColor : .secondary)
        .frame(width: Self.cellWidth, height: 26)
        .help("Column \(Self.columnName(column)): insert, move, align or delete")
    }

    private func rowHeader(_ row: Int) -> some View {
        Menu {
            Button("Insert Row Above") { insertRow(at: row) }
            Button("Insert Row Below") { insertRow(at: row + 1) }
            Button("Move Up") { moveRow(row, by: -1) }.disabled(row == 0)
            Button("Move Down") { moveRow(row, by: 1) }.disabled(row == table.rowCount - 1)
            Divider()
            Button("Delete Row…", role: .destructive) { pendingDeletion = .row(row) }.disabled(table.rowCount < 2)
        } label: {
            Text("\(row + 1)")
                .monospacedDigit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .foregroundStyle(current.row == row ? Color.accentColor : .secondary)
        .frame(width: Self.rowHeaderWidth)
        .frame(minHeight: 30)
        .help(row < table.headerRows ? "Header row \(row + 1): insert, move or delete" : "Row \(row + 1): insert, move or delete")
    }

    private func cellField(_ cell: Cell) -> some View {
        let isHeader = cell.row < table.headerRows
        let isCurrent = current == cell
        let alignment = table.format == .pipe && cell.column < table.alignments.count ? table.alignments[cell.column] : .none
        return TextField("", text: cellBinding(cell), axis: table.format == .list ? .vertical : .horizontal)
            .textFieldStyle(.plain)
            .lineLimit(table.format == .list ? 1...8 : 1...1)
            .fontWeight(isHeader ? .semibold : .regular)
            .multilineTextAlignment(alignment == .right ? .trailing : alignment == .center ? .center : .leading)
            .focused($focused, equals: cell)
            .onSubmit {
                // Return goes to the cell below, as in a spreadsheet.
                if cell.row + 1 < table.rowCount { focused = Cell(row: cell.row + 1, column: cell.column) }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .frame(width: Self.cellWidth, alignment: .leading)
            .frame(minHeight: 30, maxHeight: .infinity, alignment: .topLeading)
            .background(isHeader ? Color.accentColor.opacity(0.1) : Color(nsColor: .textBackgroundColor))
            .overlay(Rectangle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: isCurrent ? 2 : 0))
            .contentShape(Rectangle())
            .onTapGesture { focused = cell }
    }

    private func cellBinding(_ cell: Cell) -> Binding<String> {
        Binding(
            get: { table.rows.indices.contains(cell.row) && table.rows[cell.row].indices.contains(cell.column) ? table.rows[cell.row][cell.column] : "" },
            set: { value in
                guard table.rows.indices.contains(cell.row), table.rows[cell.row].indices.contains(cell.column) else { return }
                // Pipe table cells are one line.
                table.rows[cell.row][cell.column] = table.format == .pipe ? value.replacingOccurrences(of: "\n", with: " ") : value
            }
        )
    }

    private func alignmentBinding(_ column: Int) -> Binding<MystTable.Alignment> {
        Binding(
            get: { table.alignments.indices.contains(column) ? table.alignments[column] : .none },
            set: { if table.alignments.indices.contains(column) { table.alignments[column] = $0 } }
        )
    }

    private func select(_ cell: Cell) {
        let target = Cell(row: min(max(0, cell.row), table.rowCount - 1), column: min(max(0, cell.column), table.columnCount - 1))
        current = target
        DispatchQueue.main.async { focused = target }
    }

    private func insertRow(at index: Int) {
        table.insertRow(at: index)
        select(Cell(row: index, column: current.column))
    }

    private func insertColumn(at index: Int) {
        table.insertColumn(at: index)
        select(Cell(row: current.row, column: index))
    }

    private func moveRow(_ row: Int, by offset: Int) {
        table.moveRow(from: row, to: row + offset)
        select(Cell(row: row + offset, column: current.column))
    }

    private func moveColumn(_ column: Int, by offset: Int) {
        table.moveColumn(from: column, to: column + offset)
        select(Cell(row: current.row, column: column + offset))
    }

    private func delete(_ deletion: Deletion) {
        focused = nil
        switch deletion {
        case .row(let row):
            table.removeRow(at: row)
            select(Cell(row: min(row, table.rowCount - 1), column: current.column))
        case .column(let column):
            table.removeColumn(at: column)
            select(Cell(row: current.row, column: min(column, table.columnCount - 1)))
        }
    }

    private var deletionTitle: String {
        switch pendingDeletion {
        case .row(let row): "Delete row \(row + 1)?"
        case .column(let column): "Delete column \(Self.columnName(column))?"
        case nil: ""
        }
    }

    private func deletionMessage(_ deletion: Deletion) -> String {
        let cells: [String]
        var note = ""
        switch deletion {
        case .row(let row):
            cells = table.rows.indices.contains(row) ? table.rows[row] : []
            if row == 0, table.format == .pipe { note = " The next row becomes the header row." }
        case .column(let column):
            cells = table.rows.compactMap { $0.indices.contains(column) ? $0[column] : nil }
        }
        let filled = cells.map { MystTable.oneLine($0) }.filter { !$0.isEmpty }
        guard !filled.isEmpty else { return "Its cells are empty." + note }
        let shown = filled.prefix(3).map { "“" + ($0.count > 30 ? $0.prefix(29) + "…" : $0) + "”" }
        let more = filled.count > 3 ? " and \(filled.count - 3) more" : ""
        return "Its text is deleted: \(shown.joined(separator: ", "))\(more).\(note) Cancel in the assistant keeps the page as it is."
    }

    // MARK: Table settings

    private var settings: some View {
        Form {
            Section {
                Picker("Format", selection: Binding(get: { table.format }, set: { table.convert(to: $0) })) {
                    Text("Pipe table").tag(MystTable.Format.pipe)
                    Text("List table").tag(MystTable.Format.list)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(formatNote).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("Caption and Label") {
                TextField("Caption", text: $table.caption, prompt: Text("No caption"), axis: .vertical)
                    .lineLimit(1...3)
                TextField("Label", text: $table.label, prompt: Text("tbl-name"))
                Picker("Numbered", selection: $table.enumerated) {
                    Text("As the book").tag(Bool?.none)
                    Text("Yes").tag(Bool?.some(true))
                    Text("No").tag(Bool?.some(false))
                }
            }
            Section("Layout") {
                if table.format == .list {
                    Stepper("Header rows: \(table.headerRows)", value: $table.headerRows, in: 0...table.rowCount)
                } else {
                    Picker("Column \(Self.columnName(current.column)) text", selection: alignmentBinding(current.column)) {
                        ForEach(MystTable.Alignment.allCases, id: \.self) { Text(Self.alignmentName($0)).tag($0) }
                    }
                }
                if table.format == .list {
                    // mystmd places only list tables (a pipe table's `:align:` is ignored).
                    Picker("On the page", selection: $table.tableAlignment) {
                        ForEach(MystTable.Alignment.allCases, id: \.self) { Text(Self.alignmentName($0)).tag($0) }
                    }
                }
                Toggle("Full width in PDF", isOn: classBinding("full-width"))
                TextField("CSS class", text: $table.className, prompt: Text("None"))
            }
            Section {
                Button("Look of All Tables…", systemImage: "paintbrush", action: showTableStyle)
            } footer: {
                Text("Font, size and colours of tables are set for the whole book in the Style editor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }

    private var formatNote: String {
        switch table.format {
        case .pipe:
            "One header row, cells of one line, text aligned per column."
        case .list:
            (["Any number of header rows; cells may have several lines and lists."] + table.pipeConversionLosses.map { "As a pipe table: " + $0 })
                .joined(separator: "\n")
        }
    }

    private func classBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { table.className.split(separator: " ").contains { $0 == name } },
            set: { on in
                var classes = table.className.split(separator: " ").map(String.init).filter { $0 != name }
                if on { classes.append(name) }
                table.className = classes.joined(separator: " ")
            }
        )
    }

    static func alignmentName(_ alignment: MystTable.Alignment) -> String {
        switch alignment {
        case .none: "Default"
        case .left: "Left"
        case .center: "Centre"
        case .right: "Right"
        }
    }

    static func alignmentSymbol(_ alignment: MystTable.Alignment) -> String {
        switch alignment {
        case .none, .left: "text.alignleft"
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        }
    }
}

/// The pink “TA” circle, as the editor draws it next to a table.
struct TableAssistantBadge: View {
    var size: CGFloat = 18
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        Circle()
            .fill(dark ? Color(red: 0.42, green: 0.2, blue: 0.3) : Color(red: 1, green: 0.84, blue: 0.9))
            .overlay(
                Text("TA")
                    .font(.system(size: size * 0.47, weight: .heavy))
                    .foregroundStyle(dark ? Color(red: 1, green: 0.8, blue: 0.88) : Color(red: 0.68, green: 0.16, blue: 0.4))
            )
            .frame(width: size, height: size)
    }
}
