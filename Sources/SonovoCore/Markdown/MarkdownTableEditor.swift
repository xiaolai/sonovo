import Foundation

/// Source-level table commands.
///
/// Every command rewrites only the enclosing table block. The scanner is the
/// editing model: it keeps every authored cell, including short and overlong
/// rows, and it preserves escaped pipes and inline code as raw text.
public enum MarkdownTableCommand: Sendable, Equatable {
    case insert(rows: Int, columns: Int)
    case insertRowAbove
    case insertRowBelow
    case deleteRow
    case insertColumnLeft
    case insertColumnRight
    case deleteColumn
    case deleteTable
    case setAlignment(TableBlock.Alignment)
    case format
}

public enum MarkdownTableRefusal: String, Sendable, Equatable {
    case malformedTable
    case headerRow
    case lastColumn
    case lastRow
}

public struct MarkdownTableEdit: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case handled
        case refused(MarkdownTableRefusal)
        case notApplicable
    }

    public let outcome: Outcome
    /// The source range to replace. Only the table block (plus one trailing
    /// newline for row/table deletion) is ever touched.
    public let range: Range<Int>?
    public let replacement: String?
    /// The selection after the edit, in the final source coordinates.
    public let selection: Range<Int>?

    public init(
        outcome: Outcome,
        range: Range<Int>? = nil,
        replacement: String? = nil,
        selection: Range<Int>? = nil
    ) {
        self.outcome = outcome
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }

    public static let notApplicable = MarkdownTableEdit(
        outcome: .notApplicable
    )

    public static func refused(_ reason: MarkdownTableRefusal) -> Self {
        MarkdownTableEdit(outcome: .refused(reason))
    }
}

/// What a Tab/Shift+Tab in a table should do.
public enum MarkdownTableNavigation: Sendable, Equatable {
    /// Select another cell without editing.
    case select(Range<Int>)
    /// A structural edit (Tab in the last cell appends a row).
    case edit(MarkdownTableEdit)
    /// The table is malformed or the caret is on the delimiter row; make no
    /// change and do not fall through to spaces.
    case refused
    case notApplicable
}

public enum MarkdownTableEditor {
    // MARK: - Cell navigation

    /// Moves between the cells of the table containing the caret. Tab in the
    /// last cell appends a row; Shift+Tab in the first cell does nothing.
    public static func navigate(
        source: String,
        selection: Range<Int>,
        backwards: Bool
    ) -> MarkdownTableNavigation {
        guard let table = MarkdownTableScanner.table(
            at: selection.lowerBound,
            in: source
        ) else {
            return .notApplicable
        }
        guard table.isValid else { return .refused }
        guard let target = locate(
            offset: selection.lowerBound,
            in: table
        ) else {
            return .refused
        }
        let rows = [table.header] + table.body
        guard target.rowIndex < rows.count else { return .refused }
        let row = rows[target.rowIndex]

        if backwards {
            if target.column > 0,
               target.column - 1 < row.cells.count {
                return .select(cellRange(row.cells[target.column - 1]))
            }
            if target.rowIndex > 0 {
                let previous = rows[target.rowIndex - 1]
                if let last = previous.cells.last {
                    return .select(cellRange(last))
                }
            }
            // First cell: do nothing.
            return .select(selection)
        }

        if target.column + 1 < row.cells.count {
            return .select(cellRange(row.cells[target.column + 1]))
        }
        if target.rowIndex + 1 < rows.count {
            if let first = rows[target.rowIndex + 1].cells.first {
                return .select(cellRange(first))
            }
        }
        // Last cell of the last row: append a row and select its first cell.
        return .edit(
            edit(.insertRowBelow, source: source, selection: selection)
        )
    }

    private static func cellRange(_ cell: MarkdownTable.Cell) -> Range<Int> {
        cell.range.lowerBound..<cell.range.upperBound
    }

    // MARK: - Entry point

    public static func edit(
        _ command: MarkdownTableCommand,
        source: String,
        selection: Range<Int>
    ) -> MarkdownTableEdit {
        let ns = source as NSString
        let offset = min(max(selection.lowerBound, 0), ns.length)

        if case let .insert(rows, columns) = command,
           MarkdownTableScanner.table(at: offset, in: source) == nil {
            return insertTable(
                rows: rows,
                columns: columns,
                source: source,
                offset: offset
            )
        }

        guard let table = MarkdownTableScanner.table(
            at: offset,
            in: source
        ) else {
            return .notApplicable
        }
        guard table.isValid else {
            return .refused(.malformedTable)
        }

        let target = locate(offset: offset, in: table)
        guard let target else {
            return .notApplicable
        }

        switch command {
        case .insert:
            return .refused(.malformedTable)
        case .insertRowAbove:
            return insertRow(
                table: table,
                target: target,
                above: true,
                source: source
            )
        case .insertRowBelow:
            return insertRow(
                table: table,
                target: target,
                above: false,
                source: source
            )
        case .deleteRow:
            return deleteRow(table: table, target: target, source: source)
        case .insertColumnLeft:
            return insertColumn(
                table: table,
                target: target,
                leftOf: true,
                source: source
            )
        case .insertColumnRight:
            return insertColumn(
                table: table,
                target: target,
                leftOf: false,
                source: source
            )
        case .deleteColumn:
            return deleteColumn(table: table, target: target, source: source)
        case .deleteTable:
            return deleteTable(table: table, source: source)
        case .setAlignment(let alignment):
            return setAlignment(
                table: table,
                target: target,
                alignment: alignment,
                source: source
            )
        case .format:
            return format(table: table, target: target, source: source)
        }
    }

    // MARK: - Locating

    private struct Target {
        /// 0 is the header; 1... are body rows. The delimiter row has no
        /// target: it is structural.
        let rowIndex: Int
        let column: Int
    }

    private static func locate(
        offset: Int,
        in table: MarkdownTable
    ) -> Target? {
        // A caret at the table's end is still in its last row.
        let position = offset == table.range.upperBound
            ? max(table.range.lowerBound, offset - 1)
            : offset
        if table.delimiter.range.contains(offset: position) {
            return nil
        }
        let row = ([table.header] + table.body).first {
            position >= $0.range.lowerBound
                && position <= $0.range.upperBound
        }
        guard let row else { return nil }
        let column = row.cells.firstIndex {
            position >= $0.segmentRange.lowerBound
                && position <= $0.segmentRange.upperBound
        } ?? nearestCellIndex(offset: position, row: row)
        guard let column else { return nil }
        return Target(rowIndex: row.index, column: column)
    }

    private static func nearestCellIndex(
        offset: Int,
        row: MarkdownTable.Row
    ) -> Int? {
        guard !row.cells.isEmpty else { return nil }
        return row.cells.last {
            $0.segmentRange.upperBound <= offset
        }?.column ?? 0
    }

    // MARK: - Row commands

    private static func insertRow(
        table: MarkdownTable,
        target: Target,
        above: Bool,
        source: String
    ) -> MarkdownTableEdit {
        // Existing lines stay byte-identical; only a new line is added.
        var lines = [table.header.raw, table.delimiter.raw]
            + table.body.map(\.raw)
        let widths = columnWidths(table)
        let columns = max(table.header.cells.count, 1)
        let cells = (0..<columns).map { column in
            paddedEmpty(
                width: widths.indices.contains(column)
                    ? widths[column]
                    : 3
            )
        }
        let newRow = rebuildRow(template: table.header, cells: cells)

        // Line 0 is the header, line 1 the delimiter; the target's line is
        // rowIndex + 1. A header target can only insert below the delimiter.
        let lineIndex = above
            ? max(target.rowIndex + 1, 2)
            : target.rowIndex + 2
        let insertAt = min(max(lineIndex, 2), lines.count)
        lines.insert(newRow, at: insertAt)

        let replacement = lines.joined(separator: "\n")
        let blockStart = table.range.lowerBound
        let selection = cellSelection(
            in: replacement,
            rowIndex: insertAt - 1,
            column: target.column
        )?.offset(by: blockStart)
        return MarkdownTableEdit(
            outcome: .handled,
            range: table.range.lowerBound..<table.range.upperBound,
            replacement: replacement,
            selection: selection
        )
    }

    private static func deleteRow(
        table: MarkdownTable,
        target: Target,
        source: String
    ) -> MarkdownTableEdit {
        guard target.rowIndex > 0 else {
            return .refused(.headerRow)
        }
        guard !table.body.isEmpty else {
            return .refused(.lastRow)
        }
        var lines = [table.header.raw, table.delimiter.raw]
            + table.body.map(\.raw)
        let lineIndex = target.rowIndex + 1
        guard lineIndex < lines.count else {
            return .refused(.lastRow)
        }
        lines.remove(at: lineIndex)
        let replacement = lines.joined(separator: "\n")
        let nextRow = max(
            1,
            min(target.rowIndex, table.body.count - 1)
        )
        let selection = cellSelection(
            in: replacement,
            rowIndex: nextRow,
            column: target.column
        )?.offset(by: table.range.lowerBound)
        return MarkdownTableEdit(
            outcome: .handled,
            range: table.range.lowerBound..<table.range.upperBound,
            replacement: replacement,
            selection: selection
        )
    }

    // MARK: - Column commands

    private static func insertColumn(
        table: MarkdownTable,
        target: Target,
        leftOf: Bool,
        source: String
    ) -> MarkdownTableEdit {
        let widths = columnWidths(table)
        let index = leftOf ? target.column : target.column + 1
        let width = max(
            3,
            widths[min(target.column, max(widths.count - 1, 0))]
        )

        var headerCells = table.header.cells.map(\.raw)
        headerCells.insert(
            paddedEmpty(width: width),
            at: min(index, headerCells.count)
        )
        var delimiterCells = table.delimiter.cells.map(\.raw)
        delimiterCells.insert(
            " --- ",
            at: min(index, delimiterCells.count)
        )
        var cellsByRow: [[String]] = [headerCells, delimiterCells]
        for row in table.body {
            var cells = row.cells.map(\.raw)
            cells.insert(
                paddedEmpty(width: width),
                at: min(index, cells.count)
            )
            cellsByRow.append(cells)
        }

        let replacement = rebuildLines(
            table: table,
            cellsByRow: cellsByRow
        )
        let selection = cellSelection(
            in: replacement,
            rowIndex: target.rowIndex,
            column: index
        )?.offset(by: table.range.lowerBound)
        return MarkdownTableEdit(
            outcome: .handled,
            range: table.range.lowerBound..<table.range.upperBound,
            replacement: replacement,
            selection: selection
        )
    }

    private static func deleteColumn(
        table: MarkdownTable,
        target: Target,
        source: String
    ) -> MarkdownTableEdit {
        let columns = table.header.cells.count
        guard columns > 1 else {
            return .refused(.lastColumn)
        }
        var cellsByRow: [[String]] = []
        for row in [table.header, table.delimiter] + table.body {
            var cells = row.cells.map(\.raw)
            if target.column < cells.count {
                cells.remove(at: target.column)
            }
            cellsByRow.append(cells)
        }
        let replacement = rebuildLines(
            table: table,
            cellsByRow: cellsByRow
        )
        let column = min(target.column, max(columns - 2, 0))
        let selection = cellSelection(
            in: replacement,
            rowIndex: target.rowIndex,
            column: column
        )?.offset(by: table.range.lowerBound)
        return MarkdownTableEdit(
            outcome: .handled,
            range: table.range.lowerBound..<table.range.upperBound,
            replacement: replacement,
            selection: selection
        )
    }

    private static func deleteTable(
        table: MarkdownTable,
        source: String
    ) -> MarkdownTableEdit {
        let ns = source as NSString
        var upper = table.range.upperBound
        if upper < ns.length, ns.character(at: upper) == 0x0A {
            upper += 1
        }
        return MarkdownTableEdit(
            outcome: .handled,
            range: table.range.lowerBound..<upper,
            replacement: "",
            selection: table.range.lowerBound..<table.range.lowerBound
        )
    }

    // MARK: - Alignment and format

    private static func setAlignment(
        table: MarkdownTable,
        target: Target,
        alignment: TableBlock.Alignment,
        source: String
    ) -> MarkdownTableEdit {
        var cells = table.delimiter.cells.map(\.raw)
        guard target.column < cells.count else {
            return .notApplicable
        }
        cells[target.column] = delimiterSegment(
            replacing: cells[target.column],
            alignment: alignment
        )
        var cellsByRow: [[String]] = [
            table.header.cells.map(\.raw),
            cells
        ]
        cellsByRow.append(
            contentsOf: table.body.map { $0.cells.map(\.raw) }
        )
        let replacement = rebuildLines(
            table: table,
            cellsByRow: cellsByRow
        )
        let selection = cellSelection(
            in: replacement,
            rowIndex: target.rowIndex,
            column: target.column
        )?.offset(by: table.range.lowerBound)
        return MarkdownTableEdit(
            outcome: .handled,
            range: table.range.lowerBound..<table.range.upperBound,
            replacement: replacement,
            selection: selection
        )
    }

    private static func format(
        table: MarkdownTable,
        target: Target,
        source: String
    ) -> MarkdownTableEdit {
        let widths = columnWidths(table)
        let replacement = rebuiltRows(table, widths: widths)
            .joined(separator: "\n")
        let selection = cellSelection(
            in: replacement,
            rowIndex: target.rowIndex,
            column: target.column
        )?.offset(by: table.range.lowerBound)
        return MarkdownTableEdit(
            outcome: .handled,
            range: table.range.lowerBound..<table.range.upperBound,
            replacement: replacement,
            selection: selection
        )
    }

    // MARK: - Row rebuilding

    private static func blockStart(_ table: MarkdownTable) -> Int {
        table.range.lowerBound
    }

    private static func isDelimiterRow(
        _ row: MarkdownTable.Row,
        table: MarkdownTable
    ) -> Bool {
        row.range == table.delimiter.range
    }

    /// Column widths from the trimmed content, with at least three columns so
    /// a delimiter cell always fits.
    private static func columnWidths(_ table: MarkdownTable) -> [Int] {
        var widths: [Int] = []
        for row in [table.header] + table.body {
            for cell in row.cells {
                while widths.count <= cell.column {
                    widths.append(3)
                }
                widths[cell.column] = max(
                    widths[cell.column],
                    cell.content.count
                )
            }
        }
        return widths.isEmpty ? [3] : widths
    }

    private static func rebuiltRows(
        _ table: MarkdownTable,
        widths: [Int]
    ) -> [String] {
        let columns = table.header.cells.count
        var rows: [String] = []
        rows.append(
            rowLine(
                table.header,
                widths: widths,
                columns: columns,
                delimiter: false
            )
        )
        rows.append(
            rowLine(
                table.delimiter,
                widths: widths,
                columns: columns,
                delimiter: true
            )
        )
        for row in table.body {
            rows.append(
                rowLine(
                    row,
                    widths: widths,
                    columns: columns,
                    delimiter: false
                )
            )
        }
        return rows
    }

    private static func rowLine(
        _ row: MarkdownTable.Row,
        widths: [Int],
        columns: Int,
        delimiter: Bool
    ) -> String {
        var cells: [String] = []
        for column in 0..<columns {
            let width = column < widths.count ? widths[column] : 3
            if let cell = row.cells.first(where: { $0.column == column }) {
                if delimiter {
                    cells.append(
                        delimiterSegment(
                            replacing: cell.raw,
                            alignment: tableAlignment(
                                cell.content
                            ),
                            width: width,
                            normalizePadding: true
                        )
                    )
                } else {
                    cells.append(padded(cell.content, width: width))
                }
            } else {
                cells.append(
                    delimiter ? " --- " : paddedEmpty(width: width)
                )
            }
        }
        // Cells past the header count are malformed but authored; keep them
        // verbatim rather than dropping data.
        for cell in row.cells where cell.column >= columns {
            cells.append(cell.raw)
        }
        return rebuildRow(template: row, cells: cells)
    }

    private static func rebuildLines(
        table: MarkdownTable,
        cellsByRow: [[String]]
    ) -> String {
        let rows = [table.header, table.delimiter] + table.body
        var lines: [String] = []
        for (index, row) in rows.enumerated() {
            let cells = index < cellsByRow.count
                ? cellsByRow[index]
                : row.cells.map(\.raw)
            lines.append(rebuildRow(template: row, cells: cells))
        }
        return lines.joined(separator: "\n")
    }

    private static func rebuildRow(
        template: MarkdownTable.Row,
        cells: [String]
    ) -> String {
        var line = template.containerPrefix
        if template.leadingPipe { line += "|" }
        line += cells.joined(separator: "|")
        if template.trailingPipe { line += "|" }
        return line
    }

    private static func padded(_ content: String, width: Int) -> String {
        let missing = max(0, width - content.count)
        return " " + content + String(repeating: " ", count: missing) + " "
    }

    private static func paddedEmpty(width: Int) -> String {
        " " + String(repeating: " ", count: width) + " "
    }

    private static func tableAlignment(
        _ content: String
    ) -> TableBlock.Alignment {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        let left = trimmed.hasPrefix(":")
        let right = trimmed.hasSuffix(":")
        switch (left, right) {
        case (true, true): return .center
        case (true, false): return .left
        case (false, true): return .right
        case (false, false): return .none
        }
    }

    /// Replaces the delimiter cell's marker, keeping its surrounding
    /// whitespace and its dash count (at least three).
    private static func delimiterSegment(
        replacing raw: String,
        alignment: TableBlock.Alignment,
        width: Int? = nil,
        normalizePadding: Bool = false
    ) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let markerCount = trimmed.filter { $0 == "-" }.count
        let dashes = max(3, width ?? markerCount)
        var marker = String(repeating: "-", count: dashes)
        switch alignment {
        case .none:
            break
        case .left:
            marker = ":" + marker
        case .right:
            marker += ":"
        case .center:
            marker = ":" + marker + ":"
        }
        if normalizePadding {
            return " " + marker + " "
        }
        let leading = raw.prefix(while: { $0 == " " || $0 == "\t" })
        let trailing = raw.reversed().prefix(while: {
            $0 == " " || $0 == "\t"
        }).reversed()
        return String(leading) + marker + String(trailing)
    }

    // MARK: - Inserting a new table

    private static func insertTable(
        rows: Int,
        columns: Int,
        source: String,
        offset: Int
    ) -> MarkdownTableEdit {
        let columnCount = max(1, columns)
        let rowCount = max(1, rows)
        let header = (1...columnCount).map { " Column \($0) " }
        let delimiter = (0..<columnCount).map { _ in " --- " }
        var lines = [
            "|" + header.joined(separator: "|") + "|",
            "|" + delimiter.joined(separator: "|") + "|"
        ]
        for _ in 1..<max(1, rowCount) {
            lines.append(
                "|" + (0..<columnCount)
                    .map { _ in "     " }
                    .joined(separator: "|") + "|"
            )
        }
        let block = lines.joined(separator: "\n")

        let ns = source as NSString
        let lineStart: Int = {
            var index = offset
            while index > 0, ns.character(at: index - 1) != 0x0A {
                index -= 1
            }
            return index
        }()
        let lineEnd: Int = {
            var index = offset
            while index < ns.length, ns.character(at: index) != 0x0A {
                index += 1
            }
            return index
        }()
        let lineIsEmpty = lineStart == lineEnd
        let insertion = lineIsEmpty
            ? block + "\n"
            : block + "\n\n"
        let replacement = insertion
        let selection = cellSelection(
            in: block,
            rowIndex: 1,
            column: 0
        )?.offset(by: lineStart)
            ?? (lineStart..<lineStart)
        return MarkdownTableEdit(
            outcome: .handled,
            range: lineStart..<lineStart,
            replacement: replacement,
            selection: selection
        )
    }

    // MARK: - Selection mapping

    /// Finds the target cell in a rebuilt fragment and returns its content
    /// range relative to the fragment.
    private static func cellSelection(
        in fragment: String,
        rowIndex: Int,
        column: Int
    ) -> Range<Int>? {
        guard let table = MarkdownTableScanner.tables(in: fragment).first else {
            return nil
        }
        let row: MarkdownTable.Row?
        if rowIndex == 0 {
            row = table.header
        } else if rowIndex - 1 < table.body.count {
            row = table.body[rowIndex - 1]
        } else {
            row = table.body.last
        }
        guard let row,
              let cell = row.cells.first(where: { $0.column == column })
                ?? row.cells.last else {
            return nil
        }
        return cell.range.lowerBound..<cell.range.upperBound
    }
}

private extension Range where Bound == Int {
    func offset(by amount: Int) -> Range<Int> {
        (lowerBound + amount)..<(upperBound + amount)
    }
}
